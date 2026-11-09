import Foundation

/// DPI ⇄ 传感器寄存器，1:1 复刻 `DpiConversion.cs`（`GetMouseDPIValue` / `GetDPIValueByMouseDPI`）。
/// 所有除法与上游一致，使用向下取整整数除法。
public enum DpiConversion {
    public static let dpiMin = 50
    public static let dpiMax = 26000

    public static func clamp(_ dpi: Int) -> Int {
        min(max(dpi, dpiMin), dpiMax)
    }

    public static func toRegister(icType: UInt8, dpi: Int) -> UInt16 {
        let d = clamp(dpi)
        let value: Int
        switch icType {
        case 0x11:
            value = d > 12999 ? (d - 13000) / 1000 + 221
                : d < 10001 ? d / 50
                : (d - 10000) / 100 + 200
        case 0x05:
            value = d < 6401 ? d / 50 : (d - 6400) / 100 + 128
        case 0x25:
            value = d > 5000 ? (d - 5000) / 500 + 50 : d / 100
        case 0x26:
            value = d < 5001 ? d / 100 - 1 : (d - 5000) / 500 + 50
        case 0x31:
            value = d > 12000 ? (d - 12000) / 1000 + 120 : d / 100
        case 0x04, 0x10, 0x12, 0x35:
            value = d / 100
        default:
            value = d / 50 - 1
        }
        return UInt16(max(value, 0))
    }

    public static func fromRegister(icType: UInt8, register reg: Int) -> Int {
        switch icType {
        case 0x11:
            return reg > 0xDC ? (reg + 1) * 50
                : reg > 199 ? (reg - 100) * 100
                : reg * 50
        case 0x05:
            return reg > 0x80 ? (reg - 0x40) * 100 : reg * 50
        case 0x25:
            return reg > 0x31 ? (reg - 0x28) * 500 : reg * 100
        case 0x26:
            return reg > 0x31 ? (reg - 0x27) * 500 : reg * 100
        case 0x31:
            return reg > 0x78 ? (reg - 0x6D) * 1000 : reg * 100
        case 0x04, 0x10, 0x12, 0x35:
            return reg * 100
        default:
            return (reg + 1) * 50
        }
    }
}
