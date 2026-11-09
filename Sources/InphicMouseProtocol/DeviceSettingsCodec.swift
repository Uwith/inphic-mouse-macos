import Foundation

/// 回报率 / DPI 颜色 / 传感器 / 休眠 / 复位帧。
public enum DeviceSettingsCodec {
    public static let cmdReportRate: UInt8 = 0x02
    public static let cmdDpiColor: UInt8 = 0x04
    public static let cmdSensorLift: UInt8 = 0x06
    public static let cmdSleep: UInt8 = 0x07
    public static let cmdReportResetStep1: UInt8 = 0x0D
    public static let cmdReportResetStep2: UInt8 = 0x12

    /// `rateCode` 为档位码（非 Hz）。
    public static func encodeReportRate(_ rateCode: Int) throws -> [UInt8] {
        try MouseReport.build(command: cmdReportRate, header: [0x00, 0x01, 0x01],
                              payload: [UInt8(truncatingIfNeeded: rateCode)])
    }

    public static func encodeReportResetStep1() throws -> [UInt8] {
        try MouseReport.build(command: cmdReportResetStep1, header: [0x00, 0x01, 0x01], payload: [0x01])
    }

    public static func encodeReportResetStep2() throws -> [UInt8] {
        try MouseReport.build(command: cmdReportResetStep2, header: [0x00, 0x01, 0x00])
    }

    /// 最多 6 档 RGB（int，低字节起 R,G,B），不足补 0；头部长度固定 0x12。
    public static func encodeDpiColors(_ colors: [Int]) throws -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 18)
        for (i, color) in colors.prefix(6).enumerated() {
            payload[i * 3] = UInt8(color & 0xFF)
            payload[i * 3 + 1] = UInt8((color >> 8) & 0xFF)
            payload[i * 3 + 2] = UInt8((color >> 16) & 0xFF)
        }
        return try MouseReport.build(command: cmdDpiColor, header: [0x00, 0x01, 0x12], payload: payload)
    }

    /// `sensorFlag` bit3 → buf[6]，bit2 → buf[7]。
    public static func encodeSensorLift(liftoffHeight: Int, sensorFlag: Int) throws -> [UInt8] {
        let payload: [UInt8] = [
            UInt8(truncatingIfNeeded: liftoffHeight),
            (sensorFlag & 0x08) != 0 ? 1 : 0,
            (sensorFlag & 0x04) != 0 ? 1 : 0,
        ]
        return try MouseReport.build(command: cmdSensorLift, header: [0x00, 0x01, 0x05], payload: payload)
    }

    public static func encodeSleep(sleepLight: Int, moveWakeup: Int, moveCloseLight: Int,
                                   buttonRespondTime: Int) throws -> [UInt8] {
        let payload: [UInt8] = [
            UInt8(truncatingIfNeeded: sleepLight),
            UInt8(truncatingIfNeeded: moveWakeup),
            UInt8(truncatingIfNeeded: moveCloseLight),
            UInt8(truncatingIfNeeded: buttonRespondTime),
        ]
        return try MouseReport.build(command: cmdSleep, header: [0x00, 0x01, 0x04], payload: payload)
    }
}
