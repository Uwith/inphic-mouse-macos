import Foundation

/// 按键映射下发（0x09）。1:1 复刻 `KeyMapCodec.cs`。
public enum KeyMapCodec {
    public static let cmd: UInt8 = 0x09
    public static let keyCount = 5
    public static let entrySize = 3

    /// 出厂默认 5 键：左/右/中/侧1/侧2。
    public static let defaultPayload: [UInt8] = [
        0x10, 0x01, 0x00,
        0x10, 0x02, 0x00,
        0x10, 0x04, 0x00,
        0x10, 0x08, 0x00,
        0x10, 0x10, 0x00,
    ]

    public struct KeyEntry: Sendable, Equatable {
        public var type: UInt8
        public var v1: UInt8
        public var v2: UInt8

        public init(type: UInt8, v1: UInt8, v2: UInt8) {
            self.type = type
            self.v1 = v1
            self.v2 = v2
        }

        public static func mouse(_ buttonBit: UInt8) -> KeyEntry { .init(type: 0x10, v1: buttonBit, v2: 0) }
        public static func wheel(_ v1: UInt8) -> KeyEntry { .init(type: 0x20, v1: v1, v2: 0) }
        public static func fire(_ v1: UInt8, _ v2: UInt8) -> KeyEntry { .init(type: 0x30, v1: v1, v2: v2) }
        /// v1: 2 = DPI+ / 3 = DPI- / 1 = DPI 循环。
        public static func dpi(_ v1: UInt8) -> KeyEntry { .init(type: 0x40, v1: v1, v2: 0) }
        public static func systemFunc(_ v1: UInt8 = 0) -> KeyEntry { .init(type: 0x60, v1: v1, v2: 0) }
        public static func system() -> KeyEntry { .init(type: 0x60, v1: 0, v2: 0) }
        /// Consumer Usage：单字节（0xCD）v2=0；双字节（0x183）小端拆入 v1/v2。
        public static func media(_ usage: Int) -> KeyEntry {
            .init(type: 0x80, v1: UInt8(usage & 0xFF), v2: UInt8((usage >> 8) & 0xFF))
        }
        /// 键盘键：一般 v1=修饰掩码、v2=sysKeyCode；独立修饰键时 v1=修饰位、v2=0。
        public static func keyboard(usage: Int, modifierMask: UInt8) -> KeyEntry {
            let sys = KeyCodes.sysKeyCode(usage)
            if modifierMask == 0 && KeyCodes.isModifierUsage(usage) {
                return .init(type: 0x70, v1: sys, v2: 0)
            }
            return .init(type: 0x70, v1: modifierMask, v2: sys)
        }
        public static func keyboardCombo(modifierMask: UInt8, mainHIDUsage: UInt8) -> KeyEntry {
            .init(type: 0x70, v1: modifierMask, v2: mainHIDUsage)
        }
        /// 宏键：v1 低半字节 = 槽+1；高半字节为循环标志。
        public static func macro(_ macroSlot: Int, repeatUntilRelease: Bool = false,
                                 repeatCount: UInt8 = 0, untilAnyKey: Bool = false) -> KeyEntry {
            var v1 = UInt8(truncatingIfNeeded: macroSlot + 1)
            if repeatCount > 0 { return .init(type: 0x90, v1: v1 | 0x20, v2: repeatCount) }
            if repeatUntilRelease { v1 |= 0x10 }
            if untilAnyKey { v1 |= 0x40 }
            return .init(type: 0x90, v1: v1, v2: 0)
        }
        public static func raw(type: UInt8, v1: UInt8, v2: UInt8) -> KeyEntry {
            .init(type: type, v1: v1, v2: v2)
        }
    }

    public enum EncodeError: Error, Equatable {
        case badKeyCount(Int)
    }

    /// 宏槽 = 键下标；把条目低半字节改写为 `keyIndex + 1`，保留循环标志与 v2。
    public static func rebindMacroToKey(_ entry: KeyEntry, keyIndex: Int) -> KeyEntry {
        guard entry.type == 0x90 else { return entry }
        let v1 = UInt8((keyIndex + 1) & 0x0F) | (entry.v1 & 0xF0)
        return .init(type: 0x90, v1: v1, v2: entry.v2)
    }

    public static func macroEntryMatches(_ bound: KeyEntry, _ reference: KeyEntry) -> Bool {
        guard bound.type == 0x90, reference.type == 0x90 else { return false }
        if bound == reference { return true }
        return (bound.v1 & 0xF0) == (reference.v1 & 0xF0) && bound.v2 == reference.v2
    }

    public static func encode(_ keys: [KeyEntry]) throws -> [UInt8] {
        guard (1...9).contains(keys.count) else { throw EncodeError.badKeyCount(keys.count) }
        var payload: [UInt8] = []
        payload.reserveCapacity(keys.count * entrySize)
        for key in keys {
            payload.append(contentsOf: [key.type, key.v1, key.v2])
        }
        let header: [UInt8] = [0x00, 0x01, UInt8(keys.count * entrySize)]
        return try MouseReport.build(command: cmd, header: header, payload: payload)
    }

    public static func encodeDefault() throws -> [UInt8] {
        try MouseReport.build(command: cmd, header: [0x00, 0x01, 0x0F], payload: defaultPayload)
    }
}
