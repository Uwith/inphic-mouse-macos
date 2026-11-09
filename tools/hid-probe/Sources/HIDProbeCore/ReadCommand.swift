import Foundation
import InphicMouseProtocol

/// Phase 1 只允许的只读命令白名单。
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
        (try? MouseReport.build(command: rawValue, header: [0x00, 0x01, 0x00])) ?? []
    }
}
