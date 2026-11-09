import Foundation

/// 0x10 设备信息请求与解析。
public struct DeviceInfo: Sendable, Equatable {
    public var firmwareVersion: UInt16
    public var icType: UInt8
    public var reportRateMaxIndex: Int
    public var isCharging: Bool
    public var batteryPercent: UInt8
    public var isOnline: Bool

    public init(firmwareVersion: UInt16, icType: UInt8, reportRateMaxIndex: Int,
                isCharging: Bool, batteryPercent: UInt8, isOnline: Bool) {
        self.firmwareVersion = firmwareVersion
        self.icType = icType
        self.reportRateMaxIndex = reportRateMaxIndex
        self.isCharging = isCharging
        self.batteryPercent = batteryPercent
        self.isOnline = isOnline
    }

    /// 固件按 16 进制显示：0x0142 → "1.42"。
    public var firmwareText: String {
        String(format: "%X.%02X", firmwareVersion >> 8, firmwareVersion & 0xFF)
    }
}

public enum DeviceInfoCodec {
    public static let minimumLength = 0x0F

    public static func encodeRequest() throws -> [UInt8] {
        try MouseReport.build(command: 0x10, header: [0x00, 0x01, 0x00])
    }

    public static func parse(_ bytes: [UInt8]) -> DeviceInfo? {
        guard bytes.count >= minimumLength else { return nil }
        let rate: Int
        switch bytes[0x0B] {
        case 0x10: rate = 5
        case 0x20: rate = 6
        case 0x40: rate = 7
        default: rate = 4
        }
        return DeviceInfo(
            firmwareVersion: UInt16(bytes[9]) << 8 | UInt16(bytes[8]),
            icType: bytes[0x0A],
            reportRateMaxIndex: rate,
            isCharging: bytes[0x0C] != 0,
            batteryPercent: bytes[0x0D],
            isOnline: bytes[0x0E] != 0
        )
    }

    /// 兼容含/不含 report ID 的响应。含 ID 的响应以 0 开头、第二字节为命令码。
    public static func parseAnyOffset(_ bytes: [UInt8]) -> (offset: Int, info: DeviceInfo)? {
        let offsets = (bytes.count > 1 && bytes[0] == 0 && bytes[1] != 0) ? [1, 0] : [0, 1]
        for offset in offsets where bytes.count >= offset + minimumLength {
            if let info = parse(Array(bytes[offset...])) { return (offset, info) }
        }
        return nil
    }
}
