import Foundation

/// Inphic 33 字节下发帧。与上游 `InphicMouse.Protocol.MouseReport` 逐字节一致。
///
/// ```
/// offset 0    | 1      | 2  3  4       | 5 ........ 31        | 32
///        报告ID| 命令码 | 00 01 载荷长度 | 载荷（参与校验）      | 校验和
/// ```
public enum MouseReport {
    public static let length = 33
    public static let payloadStart = 5
    public static let payloadEnd = 31
    public static let checksumIndex = 32
    public static let maxPayload = payloadEnd - payloadStart + 1

    public enum BuildError: Error, CustomStringConvertible {
        case headerTooLong(Int)
        case payloadTooLong(Int)

        public var description: String {
            switch self {
            case .headerTooLong(let n): "header 最多 3 字节，收到 \(n)"
            case .payloadTooLong(let n): "payload 最多 \(MouseReport.maxPayload) 字节，收到 \(n)"
            }
        }
    }

    /// 组装一帧。`reportID` 写入 `buf[0]`，默认 0；`header` 写入 `buf[2...4]`（不足补 0）。
    public static func build(
        command: UInt8,
        header: [UInt8] = [],
        payload: [UInt8] = [],
        reportID: UInt8 = 0
    ) throws -> [UInt8] {
        guard header.count <= 3 else { throw BuildError.headerTooLong(header.count) }
        guard payload.count <= maxPayload else { throw BuildError.payloadTooLong(payload.count) }

        var buf = [UInt8](repeating: 0, count: length)
        buf[0] = reportID
        buf[1] = command
        for (i, b) in header.enumerated() { buf[2 + i] = b }
        for (i, b) in payload.enumerated() { buf[payloadStart + i] = b }
        buf[checksumIndex] = checksum(buf)
        return buf
    }

    /// `sum(buf[5...31]) & 0xFF`。
    public static func checksum(_ buf: [UInt8]) -> UInt8 {
        var sum = 0
        for i in payloadStart...payloadEnd where i < buf.count { sum &+= Int(buf[i]) }
        return UInt8(sum & 0xFF)
    }

    public static func verify(_ buf: [UInt8]) -> Bool {
        buf.count >= length && buf[checksumIndex] == checksum(buf)
    }
}

/// 无副作用的只读请求帧（Phase 1 仅允许这些命令）。
public enum ReadCommand: UInt8, CaseIterable, Sendable {
    case deviceInfo = 0x10
    case handshake = 0x11
    case reportRate = 0x12
    case dpi = 0x13
    case dpiColor = 0x14
    case light = 0x15
    case sensor = 0x16
    case sleep = 0x17
    case wirelessFirmware = 0x20

    public var title: String {
        switch self {
        case .deviceInfo: "设备信息 0x10"
        case .handshake: "会话握手 0x11"
        case .reportRate: "回报率 0x12"
        case .dpi: "DPI 档位 0x13"
        case .dpiColor: "DPI 颜色 0x14"
        case .light: "灯光 0x15"
        case .sensor: "传感器 0x16"
        case .sleep: "休眠 0x17"
        case .wirelessFirmware: "无线固件 0x20"
        }
    }

    public var frame: [UInt8] {
        // 上游 ReadFrame: header [0x00, 0x01, 0x00]，无载荷。
        (try? MouseReport.build(command: rawValue, header: [0x00, 0x01, 0x00])) ?? []
    }
}

public enum Hex {
    public static func string(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// 0x10 响应解析。偏移基于「已剥掉 report ID」的响应缓冲。
public struct DeviceInfo: Sendable, Equatable {
    public var firmwareVersion: UInt16
    public var icType: UInt8
    public var reportRateMaxIndex: Int
    public var isCharging: Bool
    public var batteryPercent: UInt8
    public var isOnline: Bool

    public var firmwareText: String {
        String(format: "%X.%02X", firmwareVersion >> 8, firmwareVersion & 0xFF)
    }
}

public enum DeviceInfoCodec {
    public static let minimumLength = 0x0F

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

    /// 尝试剥掉 report ID 前后的两种偏移，返回第一个能解析出的结果。
    /// 含 report ID 的响应以 0 开头、第二字节为命令码，因此优先尝试偏移 1。
    public static func parseAnyOffset(_ bytes: [UInt8]) -> (offset: Int, info: DeviceInfo)? {
        let offsets = (bytes.count > 1 && bytes[0] == 0 && bytes[1] != 0) ? [1, 0] : [0, 1]
        for offset in offsets where bytes.count >= offset + minimumLength {
            if let info = parse(Array(bytes[offset...])) { return (offset, info) }
        }
        return nil
    }
}
