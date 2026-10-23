import Foundation

import SMCKit

@objc protocol HelperXPCProtocol {
    func version(withReply reply: @escaping (String) -> Void)
    func adapterState(withReply reply: @escaping (Bool, Error?) -> Void)
    func setAdapter(enabled: Bool, withReply reply: @escaping (Error?) -> Void)
    func setDischarge(enabled: Bool, floorPercent: Int, hardwarePercent: Bool, withReply reply: @escaping (Error?) -> Void)
    func dischargeState(withReply reply: @escaping (Bool, Int, Error?) -> Void)
    func writeKey(_ key: String, value: Data, withReply reply: @escaping (Error?) -> Void)
    func setLowPowerMode(enabled: Bool, withReply reply: @escaping (Error?) -> Void)
}


let usage = """
smcctl — AppleSMC user client CLI

USAGE:
  smcctl smc2-read <KEY>            Read via verified ABI (selector 2)
  smcctl smc2-write <KEY> <HEX>     Write via verified ABI (root; charge keys)
  smcctl helper-test                XPC round-trip (version + adapter state)
  smcctl helper-adapter <on|off>    Adapter control via XPC
  smcctl helper-discharge <cmd>     Discharge session: on <floor> | off | state
  smcctl helper-magsafe <color>     MagSafe LED via XPC: system|off|green|orange|blink-slow|blink-fast|blink-off
  smcctl helper-lpm <on|off>        macOS Low Power Mode via XPC (daemon pmset)

"""

// MARK: - Legacy classic-ABI wire format (unused, kept for reference)
//
// The classic selector-5/6/8/9 calls return kIOReturnUnsupported on current
// firmware; not used by current commands.


extension UnsafeRawBufferPointer {
    func loadUnaligned<T>(as type: T.Type, fromByteOffset offset: Int) -> T {
        baseAddress!.advanced(by: offset).withMemoryRebound(to: T.self, capacity: 1) { $0.pointee }
    }
}

func hexBytes(_ s: String) -> [UInt8]? {
    let clean = s.split(separator: "-").joined()
    guard clean.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var iter = clean.makeIterator()
    while let hi = iter.next(), let lo = iter.next() {
        guard let h = UInt8(String(hi), radix: 16), let l = UInt8(String(lo), radix: 16) else { return nil }
        out.append(h << 4 | l)
    }
    return out
}

func run() -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    args.removeAll { $0 == "--force" }

    func client() throws -> AppleSMCClient {
        try AppleSMCClient()
    }

    guard let command = args.first else {
        print(usage); return 64
    }
    let rest = Array(args.dropFirst())

    do {
        switch command {
        case "helper-adapter":
            // helper-adapter <on|off> — privileged adapter control via XPC.
            guard let arg = rest.first, arg == "on" || arg == "off" else {
                print("usage: helper-adapter <on|off>"); return 64
            }
            let conn = NSXPCConnection(machServiceName: "com.chargekit.helper", options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
            conn.resume()
            let sem = DispatchSemaphore(value: 0)
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                print("XPC error: \(error.localizedDescription)")
                sem.signal()
            } as! HelperXPCProtocol
            proxy.setAdapter(enabled: arg == "on") { error in
                if let error {
                    print("setAdapter(\(arg)) FAILED: \(error.localizedDescription)")
                } else {
                    print("setAdapter(\(arg)) OK")
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 10)
            conn.invalidate()
        case "helper-discharge":
            // helper-discharge on <floor> [macos|hw] | off | state — daemon discharge session.
            let conn = NSXPCConnection(machServiceName: "com.chargekit.helper", options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
            conn.resume()
            let sem = DispatchSemaphore(value: 0)
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                print("XPC error: \(error.localizedDescription)")
                sem.signal()
            } as! HelperXPCProtocol
            switch rest.first {
            case "on":
                guard let floor = Int(rest.count > 1 ? rest[1] : "") else {
                    print("usage: helper-discharge on <floor> [macos|hw] | off | state"); return 64
                }
                let basis = rest.count > 2 ? rest[2] : "hw"
                guard basis == "hw" || basis == "macos" else {
                    print("unknown basis '\(basis)' (expected hw or macos)"); return 64
                }
                let hardware = basis == "hw"
                proxy.setDischarge(enabled: true, floorPercent: floor, hardwarePercent: hardware) { error in
                    print(error.map { "setDischarge(on, \(floor), \(basis)) FAILED: \($0.localizedDescription)" }
                        ?? "setDischarge(on, \(floor), \(basis)) OK")
                    sem.signal()
                }
            case "off":
                proxy.setDischarge(enabled: false, floorPercent: 0, hardwarePercent: true) { error in
                    print(error.map { "setDischarge(off) FAILED: \($0.localizedDescription)" }
                        ?? "setDischarge(off) OK")
                    sem.signal()
                }
            case "state":
                proxy.dischargeState { active, floor, error in
                    if let error {
                        print("dischargeState error: \(error.localizedDescription)")
                    } else {
                        print("discharge: \(active ? "active" : "inactive") floor=\(floor)")
                    }
                    sem.signal()
                }
            default:
                print("usage: helper-discharge on <floor> [macos|hw] | off | state"); conn.invalidate(); return 64
            }
            _ = sem.wait(timeout: .now() + 10)
            conn.invalidate()
        case "helper-magsafe":
            // helper-magsafe <color> — MagSafe LED color via daemon (root write to ACLC).
            // Values mirror Battery-Toolkit SMCComm+MagSafe (BSD-3-Clause, single write).
            guard let name = rest.first else {
                print("usage: helper-magsafe system|off|green|orange|blink-slow|blink-fast|blink-off"); return 64
            }
            let colors: [String: UInt8] = [
                "system": 0x00, "off": 0x01, "green": 0x03, "orange": 0x04,
                "blink-slow": 0x06, "blink-fast": 0x07, "blink-off": 0x19,
            ]
            guard let color = colors[name] else {
                print("unknown color \(name); usage: helper-magsafe system|off|green|orange|blink-slow|blink-fast|blink-off")
                return 64
            }
            let conn = NSXPCConnection(machServiceName: "com.chargekit.helper", options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
            conn.resume()
            let sem = DispatchSemaphore(value: 0)
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                print("XPC error: \(error.localizedDescription)")
                sem.signal()
            } as! HelperXPCProtocol
            proxy.writeKey("ACLC", value: Data([color])) { error in
                print(error.map { "magsafe \(name) (0x\(String(color, radix: 16))) FAILED: \($0.localizedDescription)" }
                    ?? "magsafe \(name) (0x\(String(color, radix: 16))) OK")
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 10)
            conn.invalidate()
        case "helper-lpm":
            // helper-lpm <on|off> — macOS Low Power Mode via daemon (root pmset).
            guard let arg = rest.first, arg == "on" || arg == "off" else {
                print("usage: helper-lpm <on|off>"); return 64
            }
            let conn = NSXPCConnection(machServiceName: "com.chargekit.helper", options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
            conn.resume()
            let sem = DispatchSemaphore(value: 0)
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                print("XPC error: \(error.localizedDescription)")
                sem.signal()
            } as! HelperXPCProtocol
            proxy.setLowPowerMode(enabled: arg == "on") { error in
                print(error.map { "setLowPowerMode(\(arg)) FAILED: \($0.localizedDescription)" }
                    ?? "setLowPowerMode(\(arg)) OK (check: pmset -g | grep lowpowermode)")
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 10)
            conn.invalidate()
        case "helper-test":
            // XPC round-trip test against the ChargeKitHelper daemon.
            let conn = NSXPCConnection(machServiceName: "com.chargekit.helper", options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
            conn.resume()
            let sem = DispatchSemaphore(value: 0)
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                print("XPC error: \(error.localizedDescription)")
                sem.signal()
            } as! HelperXPCProtocol
            proxy.version { v in
                print("helper version: \(v)")
                proxy.adapterState { enabled, error in
                    if let error {
                        print("adapterState error: \(error.localizedDescription)")
                    } else {
                        print("adapter enabled: \(enabled)")
                    }
                    sem.signal()
                }
            }
            _ = sem.wait(timeout: .now() + 10)
            conn.invalidate()
        case "smc2-write":
            // Write via gosmc ABI: smc2-write <KEY> <HEXBYTES e.g. 01>
            guard rest.count >= 2, let bytes = hexBytes(rest[1]), !bytes.isEmpty, bytes.count <= 32 else {
                print("smc2-write <KEY> <HEX> (max 32 bytes)"); return 64
            }
            let cli = try client()
            func keyFourCC(_ s: String) -> UInt32 {
                var v: UInt32 = 0
                for b in s.utf8 { v = (v << 8) | UInt32(b) }
                return v
            }
            func build(key: UInt32, sub: UInt8, dataSize: UInt32 = 0, dataType: UInt32 = 0, payload: [UInt8] = []) -> [UInt8] {
                var b = [UInt8](repeating: 0, count: 80)
                b.replaceSubrange(0..<4, with: withUnsafeBytes(of: key.littleEndian) { Array($0) })
                b.replaceSubrange(28..<32, with: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
                b.replaceSubrange(32..<36, with: withUnsafeBytes(of: dataType.littleEndian) { Array($0) })
                b[42] = sub
                for (i, byte) in payload.enumerated() { b[48 + i] = byte }
                return b
            }
            func u32(_ b: [UInt8], _ off: Int) -> UInt32 {
                UInt32(b[off]) | UInt32(b[off+1]) << 8 | UInt32(b[off+2]) << 16 | UInt32(b[off+3]) << 24
            }
            let key = keyFourCC(rest[0])
            // 1) keyInfo
            let (kr1, out1) = cli.rawStructCall(selector: 2, input: build(key: key, sub: 9))
            guard kr1 == KERN_SUCCESS, u32(out1, 28) == UInt32(bytes.count) else {
                let sz = kr1 == KERN_SUCCESS ? u32(out1, 28) : 0
                print("keyInfo failed or size mismatch: kr=0x\(String(kr1, radix: 16)) size=\(sz) want=\(bytes.count)")
                return 1
            }
            let type = u32(out1, 32)
            print("old value:")
            let (krOld, outOld) = cli.rawStructCall(selector: 2, input: build(key: key, sub: 5, dataSize: UInt32(bytes.count), dataType: type))
            if krOld == KERN_SUCCESS {
                print("  0x" + outOld[48..<48+bytes.count].map { String(format: "%02x", $0) }.joined())
            }
            // 2) write (sub 6)
            let (kr2, out2) = cli.rawStructCall(selector: 2, input: build(key: key, sub: 6, dataSize: UInt32(bytes.count), dataType: type, payload: bytes))
            guard kr2 == KERN_SUCCESS, out2[40] == 0 else {
                print(String(format: "write kr=0x%08x result=%d", kr2, out2[40]))
                return 1
            }
            // 3) read back
            let (kr3, out3) = cli.rawStructCall(selector: 2, input: build(key: key, sub: 5, dataSize: UInt32(bytes.count), dataType: type))
            print("new value:")
            if kr3 == KERN_SUCCESS {
                print("  0x" + out3[48..<48+bytes.count].map { String(format: "%02x", $0) }.joined())
            }
        case "smc2-read":
            // Read via the OLD SMCKeyData_t layout + selector 2 (gosmc ABI).
            // Layout: key@0, vers@4(6B), pLimit@12(16B), keyInfo{size,type,attr}@28(12B),
            //         result@40, status@41, data8@42 (SUBCOMMAND), data32@44, bytes@48(32B)
            guard let name = rest.first, name.count == 4 else { print("smc2-read <KEY>"); return 64 }
            let cli = try client()
            func keyFourCC(_ s: String) -> UInt32 {
                var v: UInt32 = 0
                for b in s.utf8 { v = (v << 8) | UInt32(b) }
                return v
            }
            // Build the 80-byte old-layout struct manually (bytes are little-endian fields).
            func build(key: UInt32, sub: UInt8, dataSize: UInt32 = 0, dataType: UInt32 = 0) -> [UInt8] {
                var b = [UInt8](repeating: 0, count: 80)
                b.replaceSubrange(0..<4, with: withUnsafeBytes(of: key.littleEndian) { Array($0) })
                b.replaceSubrange(28..<32, with: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
                b.replaceSubrange(32..<36, with: withUnsafeBytes(of: dataType.littleEndian) { Array($0) })
                b[42] = sub
                return b
            }
            func call(_ wire: [UInt8]) -> (kern_return_t, [UInt8]) {
                cli.rawStructCall(selector: 2, input: wire)
            }
            func u32(_ b: [UInt8], _ off: Int) -> UInt32 {
                UInt32(b[off]) | UInt32(b[off+1]) << 8 | UInt32(b[off+2]) << 16 | UInt32(b[off+3]) << 24
            }
            // 1) keyInfo (sub 9)
            let key = keyFourCC(name)
            let (kr1, out1) = call(build(key: key, sub: 9))
            guard kr1 == KERN_SUCCESS else {
                print(String(format: "keyInfo(%@): kr=0x%08x", name, kr1)); return 1
            }
            let size = u32(out1, 28), type = u32(out1, 32)
            var typeBytes: [UInt8] = []
            typeBytes.append(UInt8((type >> 24) & 0xFF))
            typeBytes.append(UInt8((type >> 16) & 0xFF))
            typeBytes.append(UInt8((type >> 8) & 0xFF))
            typeBytes.append(UInt8(type & 0xFF))
            let typeName = String(decoding: typeBytes, as: UTF8.self)
            print("\(name): keyInfo size=\(size) type=\(typeName) result=\(out1[40])")
            guard size > 0, size <= 32 else { print("bad size"); return 1 }
            // 2) read (sub 5)
            let (kr2, out2) = call(build(key: key, sub: 5, dataSize: size, dataType: type))
            guard kr2 == KERN_SUCCESS else {
                print(String(format: "read(%@): kr=0x%08x", name, kr2)); return 1
            }
            let payload = Array(out2[48..<48+Int(size)])
            print("\(name) = 0x" + payload.map { String(format: "%02x", $0) }.joined())
        default:
            print("unknown command. run without arguments for usage."); return 64
        }
    } catch {
        print("error: \(error)"); return 1
    }
    return 0
}

struct Stderr: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(string.data(using: .utf8)!)
    }
}
var standardError = Stderr()

exit(run())
