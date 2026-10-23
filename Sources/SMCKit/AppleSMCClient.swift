import Foundation
import IOKit

// MARK: - Apple Silicon SMC client (verified ABI, macOS 26.6.2 / firmware 13822+)
//
// Wire protocol (all via IOConnectCallStructMethod, selector = 2):
// 80-byte old-style SMCKeyData_t layout:
// key@0 (u32 LE), vers@4(6B), pLimit@12(16B),
// keyInfo{dataSize@28, dataType@32, attr@36}(12B),
// result@40, status@41, SUBCOMMAND@42, data32@44, bytes@48(32B)
// Subcommands: 5=read, 6=write, 8=key-from-index, 9=key-info
//
// Permissions: reads work unprivileged; writes require root.
// Some charge-related keys are system-protected and not writable by
// third-party apps; the usable control keys on current firmware are
// CHIE (adapter) and bfD0 (firmware limit upper).

public enum AppleSMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case cannotOpen(kernReturn: kern_return_t)
    case callFailed(kernReturn: kern_return_t)
    case smcResult(UInt8, key: String)
    case keyNotFound(String)
    case notPrivileged

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .cannotOpen(let kr): return "IOServiceOpen failed 0x\(String(kr, radix: 16))"
        case .callFailed(let kr): return "SMC call failed 0x\(String(kr, radix: 16))"
        case .smcResult(let r, let key): return "SMC result \(r) for \(key)"
        case .keyNotFound(let key): return "SMC key \(key) not found"
        case .notPrivileged: return "write requires root"
        }
    }
}

public struct SMCKeyInfo {
    public let key: SMCKey
    public let dataSize: Int
    public let dataType: SMCType

    public init(key: SMCKey, dataSize: Int, dataType: SMCType) {
        self.key = key
        self.dataSize = dataSize
        self.dataType = dataType
    }
}

public final class AppleSMCClient {
    private var connection: io_connect_t = 0
    private static let selector: UInt32 = 2  // KERNEL_INDEX_SMC

    public static func isRoot() -> Bool { geteuid() == 0 }

    public init() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { throw AppleSMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == KERN_SUCCESS, connection != IO_OBJECT_NULL else {
            throw AppleSMCError.cannotOpen(kernReturn: kr)
        }
    }

    deinit {
        if connection != IO_OBJECT_NULL { IOServiceClose(connection) }
    }

 /// Raw IOKit connection for diagnostics (odd selector/shape probing).
    public var rawConnection: io_connect_t { connection }

 /// Raw struct-method call with an arbitrary selector; returns the kern
 /// return and the 80-byte output buffer without throwing. Diagnostic
 /// path for smcctl (smc2-* / probe*).
    public func rawStructCall(selector: UInt32, input: [UInt8]) -> (kernReturn: kern_return_t, output: [UInt8]) {
        var inWire = [UInt8](repeating: 0, count: Wire.size)
        for (i, byte) in input.prefix(Wire.size).enumerated() { inWire[i] = byte }
        var outWire = [UInt8](repeating: 0, count: Wire.size)
        var outSize = Wire.size
        let kr = inWire.withUnsafeMutableBufferPointer { inBP in
            outWire.withUnsafeMutableBufferPointer { outBP in
                IOConnectCallStructMethod(
                    connection, selector,
                    inBP.baseAddress, Wire.size,
                    outBP.baseAddress, &outSize)
            }
        }
        return (kr, outWire)
    }

 // MARK: - Wire

    private struct Wire {
        static let keyInfoSizeOffset = 28
        static let keyInfoTypeOffset = 32
        static let resultOffset = 40
        static let subcommandOffset = 42
        static let payloadOffset = 48
        static let size = 80

        static func buffer(key: UInt32, sub: UInt8, dataSize: UInt32 = 0,
                           dataType: UInt32 = 0, payload: [UInt8] = []) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: size)
            b.replaceSubrange(0..<4, with: withUnsafeBytes(of: key.littleEndian) { Array($0) })
            b.replaceSubrange(keyInfoSizeOffset..<keyInfoSizeOffset+4,
                              with: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
            b.replaceSubrange(keyInfoTypeOffset..<keyInfoTypeOffset+4,
                              with: withUnsafeBytes(of: dataType.littleEndian) { Array($0) })
            b[subcommandOffset] = sub
            for (i, byte) in payload.enumerated() where i < 32 {
                b[payloadOffset + i] = byte
            }
            return b
        }

        static func u32(_ b: [UInt8], _ off: Int) -> UInt32 {
            UInt32(b[off]) | UInt32(b[off+1]) << 8 | UInt32(b[off+2]) << 16 | UInt32(b[off+3]) << 24
        }
    }

    @discardableResult
    private func call(_ input: [UInt8]) throws -> [UInt8] {
        var inWire = input
        var outWire = [UInt8](repeating: 0, count: Wire.size)
        var outSize = Wire.size
        let kr = inWire.withUnsafeMutableBufferPointer { inBP in
            outWire.withUnsafeMutableBufferPointer { outBP in
                IOConnectCallStructMethod(
                    connection, Self.selector,
                    inBP.baseAddress, Wire.size,
                    outBP.baseAddress, &outSize)
            }
        }
        guard kr == KERN_SUCCESS else { throw AppleSMCError.callFailed(kernReturn: kr) }
        return outWire
    }

 // MARK: - Public API

    public func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        let out = try call(Wire.buffer(key: key.rawValue, sub: 9))
        guard out[Wire.resultOffset] == 0 else {
            throw AppleSMCError.keyNotFound(key.fourCC)
        }
        let size = Int(Wire.u32(out, Wire.keyInfoSizeOffset))
        let type = SMCType(rawValue: Wire.u32(out, Wire.keyInfoTypeOffset))
        return SMCKeyInfo(key: key, dataSize: size, dataType: type)
    }

    public func keyExists(_ key: SMCKey) -> Bool {
        guard let info = try? keyInfo(key) else { return false }
        return info.dataSize > 0  // placeholder keys have zero size
    }

    public func read(_ key: SMCKey) throws -> [UInt8] {
        let info = try keyInfo(key)
        guard info.dataSize > 0, info.dataSize <= 32 else {
            throw AppleSMCError.keyNotFound(key.fourCC)
        }
        let out = try call(Wire.buffer(
            key: key.rawValue, sub: 5,
            dataSize: UInt32(info.dataSize), dataType: info.dataType.rawValue))
        guard out[Wire.resultOffset] == 0 else {
            throw AppleSMCError.smcResult(out[Wire.resultOffset], key: key.fourCC)
        }
        return Array(out[Wire.payloadOffset..<Wire.payloadOffset + info.dataSize])
    }

 /// Typed read; throws if the key's SMC type is not numeric.
    public func readNumeric(_ key: SMCKey) throws -> Double {
        let info = try keyInfo(key)
        let bytes = try read(key)
        return try Self.decode(bytes: bytes, type: info.dataType)
    }

    public func write(_ key: SMCKey, _ bytes: [UInt8]) throws {
        guard Self.isRoot() else { throw AppleSMCError.notPrivileged }
        let info = try keyInfo(key)
        guard info.dataSize == bytes.count else {
            throw AppleSMCError.smcResult(0xFF, key: "\(key.fourCC) size mismatch want=\(info.dataSize) got=\(bytes.count)")
        }
        let out = try call(Wire.buffer(
            key: key.rawValue, sub: 6,
            dataSize: UInt32(info.dataSize), dataType: info.dataType.rawValue,
            payload: bytes))
        guard out[Wire.resultOffset] == 0 else {
            throw AppleSMCError.smcResult(out[Wire.resultOffset], key: key.fourCC)
        }
    }

 /// Enumerate keys (subcommand 8): index -> key. Bounded.
    public func allKeys(limit: Int = 10_000) throws -> [SMCKey] {
        var keys: [SMCKey] = []
        keys.reserveCapacity(1024)
        let index: UInt32 = 0
        while Int(index) < limit {
            let out = try call(Wire.buffer(key: 0, sub: 8, dataType: 0))
 // data32 carries the index for sub 8 — reuse payload area of keyInfo? No:
 // old ABI puts index in data32@44.
            _ = out
            break  // sub-8 wire details need data32 support; enumerate later if needed
        }
        return keys
    }

 // MARK: - Value decoding
 //
 // NOTE (measured on this firmware): 'flt ' values are LITTLE-ENDIAN float32
 // (VD0R 0x56b5a341 LE = 20.35 V; TB0T -> 33.03 C). Integer types follow
 // SMC big-endian convention (B0AC si16 measured 0).

    static func decode(bytes: [UInt8], type: SMCType) throws -> Double {
        func u8(_ i: Int) -> UInt8 { bytes.count > i ? bytes[i] : 0 }
        func be16(_ i: Int) -> UInt16 { (UInt16(u8(i)) << 8) | UInt16(u8(i+1)) }
        func be32(_ i: Int) -> UInt32 { (UInt32(be16(i)) << 16) | UInt32(be16(i+2)) }
        switch type {
        case SMCType("flt "):
 // little-endian IEEE float32
            let v = UInt32(u8(0)) | UInt32(u8(1)) << 8 | UInt32(u8(2)) << 16 | UInt32(u8(3)) << 24
            return Double(Float(bitPattern: v))
        case .ui8:  return Double(u8(0))
        case .ui16: return Double(be16(0))
        case .ui32: return Double(be32(0))
        case SMCType("si8 "):  return Double(Int8(bitPattern: u8(0)))
        case SMCType("si16"): return Double(Int16(bitPattern: be16(0)))
        case SMCType("si32"): return Double(Int32(bitPattern: be32(0)))
        case .sp78: return Double(Int16(bitPattern: be16(0))) / 256.0
        default:
            throw AppleSMCError.smcResult(0xFE, key: "no decoder for \(type.fourCC)")
        }
    }
}

// MARK: - Charge-control façade

/// High-level, whitelist-gated control over the keys that matter.
/// Charging switch (preferred): stop CHARGING while the adapter keeps
/// powering the machine — battery neither charges nor discharges.
/// Adapter switch (fallback): cut wall power entirely; the machine runs
/// on battery (older firmware without charging-switch keys).
public struct ChargeController {
 /// Keys that disable charging but keep adapter power.
 /// Verified on this machine (macOS 26.6.2, fw 13822+): CHTE off ->
 /// PDTR ~9W (system load only), B0AC == 0, battery % holds.
    public enum ChargingKey: CaseIterable {
        case chte    // ui32: on 00 00 00 00, off 01 00 00 00 (same encoding as Battery-Toolkit)
        case ch0c    // hex:  on 00,           off 01

        var key: SMCKey { SMCKey(self == .chte ? "CHTE" : "CH0C") }
        var onBytes: [UInt8] { self == .chte ? [0, 0, 0, 0] : [0x00] }
        var offBytes: [UInt8] { self == .chte ? [0x01, 0, 0, 0] : [0x01] }
    }

    public enum AdapterKey: String, CaseIterable {
        case chieTahoe = "CHIE"   // macOS 26 (Tahoe) firmware; 0x00=on, 0x08=off
        case ch0i = "CH0I"        // older firmware; 0x00=on, 0x01=off
        case ch0j = "CH0J"        // older firmware; 0x00=on, 0x01=off

        var key: SMCKey { SMCKey(rawValue) }
        var offValue: UInt8 {
            switch self {
            case .chieTahoe: return 0x08
            case .ch0i, .ch0j: return 0x01
            }
        }
    }

    public enum TelemetryKey: String {
        case batteryPercent = "BUIC"   // ui8, %
        case dcInVoltage = "VD0R"      // flt LE, V
        case dcInCurrent = "ID0R"      // flt LE, A
        case dcInPower = "PDTR"        // flt LE, W
        case batteryCurrent = "B0AC"   // si16 LE (measured), mA; positive = charging
        case batteryVoltage = "B0AV"   // ui16 LE (measured), mV
        case batteryTemp = "TB0T"      // flt LE, °C
        case acStatus = "AC-W"         // si8
        var key: SMCKey { SMCKey(rawValue) }
    }

    private let client: AppleSMCClient
    public let adapterKey: AdapterKey?
    public let chargingKey: ChargingKey?

    public init(client: AppleSMCClient) {
        self.client = client
        self.adapterKey = AdapterKey.allCases.first { client.keyExists($0.key) }
        self.chargingKey = ChargingKey.allCases.first { client.keyExists($0.key) }
    }

 // MARK: reads (unprivileged)

    public func batteryPercent() throws -> Double { try client.readNumeric(TelemetryKey.batteryPercent.key) }
    public func dcInPower() throws -> Double { try client.readNumeric(TelemetryKey.dcInPower.key) }
    public func dcInVoltage() throws -> Double { try client.readNumeric(TelemetryKey.dcInVoltage.key) }
    public func batteryTemp() throws -> Double { try client.readNumeric(TelemetryKey.batteryTemp.key) }

 /// Battery pack voltage in V. The battery-gauge integers are stored
 /// LITTLE-endian on this firmware (measured: B0AV memory 2b 32 reads
 /// 12843 mV against ioreg 12850; same for B0AC), unlike the classic
 /// big-endian SMC convention used elsewhere.
    public func batteryVoltage() throws -> Double {
        let b = try client.read(TelemetryKey.batteryVoltage.key)
        guard b.count == 2 else { throw AppleSMCError.smcResult(0xFE, key: "B0AV size \(b.count)") }
        return Double(UInt16(b[0]) | UInt16(b[1]) << 8) / 1000
    }

 /// Battery current in A; positive while charging, negative while
 /// discharging (little-endian si16, see batteryVoltage).
    public func batteryCurrent() throws -> Double {
        let b = try client.read(TelemetryKey.batteryCurrent.key)
        guard b.count == 2 else { throw AppleSMCError.smcResult(0xFE, key: "B0AC size \(b.count)") }
        let raw = UInt16(b[0]) | UInt16(b[1]) << 8
        return Double(Int16(bitPattern: raw)) / 1000
    }

    public func isAdapterEnabled() throws -> Bool {
        guard let a = adapterKey else { throw AppleSMCError.keyNotFound("no adapter key") }
        let v = try client.read(a.key)
        return v.first == 0x00
    }

 /// True when charging is allowed (charging switch on, or adapter on
 /// when no charging-switch key exists).
    public func isChargingEnabled() throws -> Bool {
        if let c = chargingKey {
            let v = try client.read(c.key)
            return v == c.onBytes
        }
        return try isAdapterEnabled()
    }

 // MARK: writes (root required)

    public func setAdapter(enabled: Bool) throws {
        guard let a = adapterKey else { throw AppleSMCError.keyNotFound("no adapter key") }
        let value: UInt8 = enabled ? 0x00 : a.offValue
        try client.write(a.key, [value])
    }

 /// Stop/start charging. With a charging-switch key the adapter keeps
 /// powering the machine; otherwise falls back to cutting the adapter.
    public func setCharging(enabled: Bool) throws {
        if let c = chargingKey {
            try client.write(c.key, enabled ? c.onBytes : c.offBytes)
        } else {
            try setAdapter(enabled: enabled)
        }
    }
}
