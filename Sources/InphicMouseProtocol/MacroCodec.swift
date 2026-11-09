import Foundation

/// 宏内容上传（0x08）。1:1 复刻 `MacroCodec.cs`。
///
/// 每个动作 4 字节 `[动作类型, 延时低, 延时高, 键值]`；延时挂在**前一个动作**上，
/// DB 中的独立延时记录在编码时并入前一动作，动作之间最小 1 ms。
public enum MacroCodec {
    public static let cmd: UInt8 = 0x08
    public static let maxEventsPerFrame = 6
    public static let chunkPayload = 0x1B

    public enum EventType: UInt8, Sendable {
        case delay = 1
        case keyDown = 2
        case keyUp = 3
        case mouseDown = 4
        case mouseUp = 5
    }

    public struct MacroEvent: Sendable, Equatable {
        public var type: EventType
        public var value: Int

        public init(type: EventType, value: Int) {
            self.type = type
            self.value = value
        }

        public static func delay(_ ms: Int) -> MacroEvent { .init(type: .delay, value: ms) }
        public static func keyDown(_ vk: Int) -> MacroEvent { .init(type: .keyDown, value: vk) }
        public static func keyUp(_ vk: Int) -> MacroEvent { .init(type: .keyUp, value: vk) }
        public static func mouseDown(_ buttonBit: Int) -> MacroEvent { .init(type: .mouseDown, value: buttonBit) }
        public static func mouseUp(_ buttonBit: Int) -> MacroEvent { .init(type: .mouseUp, value: buttonBit) }
    }

    public enum EncodeError: Error, Equatable {
        case tooManyBlocks(Int)
    }

    /// `macroSlot` = 被绑定物理键的下标 `key_code`，帧内写 `slot + 1`。
    public static func encode(macroSlot: Int, events: [MacroEvent]) throws -> [[UInt8]] {
        var wire: [[UInt8]] = []
        var pendingDelay = 0

        for (index, event) in events.enumerated() {
            if event.type == .delay {
                pendingDelay += min(max(event.value, 0), 0xFFFF)
                if index == events.count - 1, !wire.isEmpty {
                    setDelay(&wire[wire.count - 1], pendingDelay)
                }
                continue
            }
            if !wire.isEmpty {
                setDelay(&wire[wire.count - 1], max(pendingDelay, 1))
            }
            pendingDelay = 0
            wire.append(buildAction(event))
        }

        var body = [UInt8](repeating: 0, count: 1 + wire.count * 4)
        body[0] = UInt8(truncatingIfNeeded: macroSlot + 1)
        for (index, action) in wire.enumerated() {
            body.replaceSubrange((1 + index * 4)..<(1 + index * 4 + 4), with: action)
        }

        if wire.count <= maxEventsPerFrame {
            let header: [UInt8] = [0x00, 0x01, UInt8(wire.count * 4 + 1)]
            return [try MouseReport.build(command: cmd, header: header, payload: body)]
        }

        let blocks = (body.count + chunkPayload - 1) / chunkPayload
        guard blocks <= 0x0F else { throw EncodeError.tooManyBlocks(blocks) }
        var frames: [[UInt8]] = []
        for block in 0..<blocks {
            let offset = block * chunkPayload
            let length = min(chunkPayload, body.count - offset)
            let header: [UInt8] = [0x00, UInt8((block << 4) | blocks), UInt8(length)]
            frames.append(try MouseReport.build(
                command: cmd,
                header: header,
                payload: Array(body[offset..<(offset + length)])
            ))
        }
        return frames
    }

    private static func buildAction(_ event: MacroEvent) -> [UInt8] {
        let type: UInt8
        let key: UInt8

        switch event.type {
        case .keyDown:
            if isModifierVK(event.value) {
                type = 0x20
                key = KeyCodes.sysKeyCode(event.value)
            } else {
                type = 0x30
                key = KeyCodes.vkToHIDUsage(event.value)
            }
        case .keyUp:
            if isModifierVK(event.value) {
                type = 0xA0
                key = KeyCodes.sysKeyCode(event.value)
            } else if event.value == 0x5B || event.value == 0x5D {
                // 复刻官方行为：Win 键松开与按下同为 0x20。
                type = 0x20
                key = KeyCodes.sysKeyCode(event.value)
            } else {
                type = 0xB0
                key = KeyCodes.vkToHIDUsage(event.value)
            }
        case .mouseDown:
            type = 0x10
            key = UInt8(truncatingIfNeeded: event.value)
        case .mouseUp:
            type = 0x90
            key = UInt8(truncatingIfNeeded: event.value)
        case .delay:
            type = 0x00
            key = UInt8(truncatingIfNeeded: event.value)
        }

        return [type, 0x01, 0x00, key]
    }

    private static func setDelay(_ action: inout [UInt8], _ ms: Int) {
        action[1] = UInt8(ms & 0xFF)
        action[2] = UInt8((ms >> 8) & 0xFF)
    }

    private static func isModifierVK(_ vk: Int) -> Bool {
        (0xA0...0xA7).contains(vk)
    }
}
