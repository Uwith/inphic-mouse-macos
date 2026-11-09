import Foundation

/// Windows VK / HID usage ↔ 硬件修饰位，1:1 复刻 `KeyCodes.cs`（上游 `GetSysKeyCode` / `GetFlashKeyCode`）。
public enum KeyCodes {
    /// 修饰键 → 硬件修饰位；非修饰键原样返回低 8 位；0 → 0。
    public static func sysKeyCode(_ usage: Int) -> UInt8 {
        switch usage {
        case 0x00: 0x00
        case 0x5B, 0xE3: 0x08 // LGui
        case 0x5C, 0xE7: 0x80 // RGui
        case 0xA0, 0xE1: 0x02 // LShift
        case 0xA1, 0xE5: 0x20 // RShift
        case 0xA2, 0xE0: 0x01 // LCtrl
        case 0xA3, 0xE4: 0x10 // RCtrl
        case 0xA4, 0xE2: 0x04 // LAlt
        case 0xA5, 0xE6: 0x40 // RAlt
        default: UInt8(usage & 0xFF)
        }
    }

    public static func isModifierUsage(_ usage: Int) -> Bool {
        (0xE0...0xE7).contains(usage)
    }

    /// Windows 虚拟键码 → HID 键盘 usage；未覆盖返回 0。
    public static func vkToHIDUsage(_ vk: Int) -> UInt8 {
        if (0x41...0x5A).contains(vk) { return UInt8(vk - 0x41 + 0x04) } // A-Z
        if (0x31...0x39).contains(vk) { return UInt8(vk - 0x31 + 0x1E) } // 1-9
        if vk == 0x30 { return 0x27 }                                   // 0
        if (0x70...0x7B).contains(vk) { return UInt8(vk - 0x70 + 0x3A) } // F1-F12
        if (0x61...0x69).contains(vk) { return UInt8(vk - 0x61 + 0x59) } // Numpad1-9
        if vk == 0x60 { return 0x62 }                                   // Numpad0

        switch vk {
        case 0x0D: return 0x28 // Enter
        case 0x1B: return 0x29 // Esc
        case 0x08: return 0x2A // Backspace
        case 0x09: return 0x2B // Tab
        case 0x20: return 0x2C // Space
        case 0xBD: return 0x2D // - _
        case 0xBB: return 0x2E // = +
        case 0xDB: return 0x2F // [ {
        case 0xDD: return 0x30 // ] }
        case 0xDC: return 0x31 // \ |
        case 0xBA: return 0x33 // ; :
        case 0xDE: return 0x34 // ' "
        case 0xC0: return 0x35 // ` ~
        case 0xBC: return 0x36 // , <
        case 0xBE: return 0x37 // . >
        case 0xBF: return 0x38 // / ?
        case 0x14: return 0x39 // CapsLock
        case 0x2C: return 0x46 // PrintScreen
        case 0x91: return 0x47 // ScrollLock
        case 0x13: return 0x48 // Pause
        case 0x2D: return 0x49 // Insert
        case 0x24: return 0x4A // Home
        case 0x21: return 0x4B // PageUp
        case 0x2E: return 0x4C // Delete
        case 0x23: return 0x4D // End
        case 0x22: return 0x4E // PageDown
        case 0x27: return 0x4F // Right
        case 0x25: return 0x50 // Left
        case 0x28: return 0x51 // Down
        case 0x26: return 0x52 // Up
        default: return 0x00
        }
    }
}
