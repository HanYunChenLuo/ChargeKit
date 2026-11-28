import Foundation

@objc public protocol HelperProtocol {
    func version(withReply reply: @escaping (String) -> Void)
    func adapterState(withReply reply: @escaping (Bool, Error?) -> Void)
    func setAdapter(enabled: Bool, withReply reply: @escaping (Error?) -> Void)
    func chargingState(withReply reply: @escaping (Bool, Error?) -> Void)
    func setCharging(enabled: Bool, withReply reply: @escaping (Error?) -> Void)
    func setDischarge(enabled: Bool, floorPercent: Int, hardwarePercent: Bool, withReply reply: @escaping (Error?) -> Void)
    func dischargeState(withReply reply: @escaping (Bool, Int, Error?) -> Void)
    func dischargeStatus(withReply reply: @escaping (Int, Int, String?) -> Void)
    func readKey(_ key: String, withReply reply: @escaping (Data?, Error?) -> Void)
    func writeKey(_ key: String, value: Data, withReply reply: @escaping (Error?) -> Void)
    func setLowPowerMode(enabled: Bool, withReply reply: @escaping (Error?) -> Void)
    func setExitRestoresCharging(enabled: Bool, withReply reply: @escaping (Error?) -> Void)
}