import Foundation
import IOKit

// MARK: - Four-char-code helpers
//
// SMCKit exposes the verified new-ABI surface only (AppleSMCClient in
// AppleSMCClient.swift). The classic selector-5/6/8/9 client was removed:
// those calls return kIOReturnUnsupported on current firmware. The legacy
// (The classic struct layout is kept here for reference.)

public struct SMCKey: RawRepresentable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ fourCC: String) {
        precondition(fourCC.utf8.count == 4, "SMC key must be exactly 4 characters")
        var value: UInt32 = 0
        for byte in fourCC.utf8 { value = (value << 8) | UInt32(byte) }
        self.rawValue = value
    }
    public var fourCC: String {
        let bytes = [
            UInt8((rawValue >> 24) & 0xFF), UInt8((rawValue >> 16) & 0xFF),
            UInt8((rawValue >> 8) & 0xFF), UInt8(rawValue & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct SMCType: RawRepresentable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ fourCC: String) {
        precondition(fourCC.utf8.count == 4, "SMC type must be exactly 4 characters")
        var value: UInt32 = 0
        for byte in fourCC.utf8 { value = (value << 8) | UInt32(byte) }
        self.rawValue = value
    }
    public var fourCC: String {
        let bytes = [
            UInt8((rawValue >> 24) & 0xFF), UInt8((rawValue >> 16) & 0xFF),
            UInt8((rawValue >> 8) & 0xFF), UInt8(rawValue & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    public static let ui8 = SMCType("ui8 ")
    public static let ui16 = SMCType("ui16")
    public static let ui32 = SMCType("ui32")
    public static let flag = SMCType("flag")
    public static let sp78 = SMCType("sp78")
    public static let fpe2 = SMCType("fpe2")
}
