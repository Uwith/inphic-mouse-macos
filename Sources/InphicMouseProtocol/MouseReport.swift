import Foundation

/// Inphic 33 字节下发帧，1:1 复刻上游 `MouseReport.cs`。
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

    public enum BuildError: Error, Equatable, CustomStringConvertible {
        case headerTooLong(Int)
        case payloadTooLong(Int)

        public var description: String {
            switch self {
            case .headerTooLong(let n): "header 最多 3 字节，收到 \(n)"
            case .payloadTooLong(let n): "payload 最多 \(MouseReport.maxPayload) 字节，收到 \(n)"
            }
        }
    }

    /// 组装一帧。`header` 写入 `buf[2...4]`（不足补 0），`payload` 从 `buf[5]` 起。
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
        for (i, byte) in header.enumerated() { buf[2 + i] = byte }
        for (i, byte) in payload.enumerated() { buf[payloadStart + i] = byte }
        buf[checksumIndex] = checksum(buf)
        return buf
    }

    /// `sum(buf[5...31]) & 0xFF`；头部不参与校验。
    public static func checksum(_ buf: [UInt8]) -> UInt8 {
        var sum = 0
        for i in payloadStart...payloadEnd where i < buf.count { sum &+= Int(buf[i]) }
        return UInt8(sum & 0xFF)
    }

    public static func verify(_ buf: [UInt8]) -> Bool {
        buf.count >= length && buf[checksumIndex] == checksum(buf)
    }
}

public enum Hex {
    public static func string(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
