import Foundation

/// 灯光模式下发（0x05）与复位（0x0E → 0x15）。
public enum LightCodec {
    public enum EncodeError: Error, Equatable {
        case mode2NeedsSevenColors(Int)
        case mode3NeedsOneColor(Int)
    }

    /// `colors` 为 int，低字节起 R,G,B；模式 2 需 7 色，模式 3 需 1 色。
    public static func encode(modeID: Int, brightness: Int, speed: Int, colors: [Int]? = nil) throws -> [UInt8] {
        let level = UInt8(((brightness & 0x0F) << 4) | (speed & 0x0F))
        switch modeID {
        case 2:
            guard let colors, colors.count >= 7 else {
                throw EncodeError.mode2NeedsSevenColors(colors?.count ?? 0)
            }
            var payload = [UInt8](repeating: 0, count: 3 + 7 * 3)
            payload[0] = UInt8(modeID)
            payload[1] = level
            payload[2] = 0x07
            for i in 0..<7 {
                writeRGB(&payload, offset: 3 + i * 3, color: colors[i])
            }
            return try MouseReport.build(command: 0x05, header: [0x00, 0x01, 0x18], payload: payload)

        case 3:
            guard let colors, let color = colors.first else {
                throw EncodeError.mode3NeedsOneColor(colors?.count ?? 0)
            }
            var payload = [UInt8](repeating: 0, count: 5)
            payload[0] = UInt8(modeID)
            payload[1] = level
            writeRGB(&payload, offset: 2, color: color)
            return try MouseReport.build(command: 0x05, header: [0x00, 0x01, 0x05], payload: payload)

        case 1:
            return try MouseReport.build(command: 0x05, header: [0x00, 0x01, 0x03],
                                         payload: [UInt8(modeID), level, 0x00])

        default:
            return try MouseReport.build(command: 0x05, header: [0x00, 0x01, 0x02],
                                         payload: [UInt8(modeID), level])
        }
    }

    public static func encodeResetStep1() throws -> [UInt8] {
        try MouseReport.build(command: 0x0E, header: [0x00, 0x01, 0x01], payload: [0x01])
    }

    public static func encodeResetStep2() throws -> [UInt8] {
        try MouseReport.build(command: 0x15, header: [0x00, 0x01, 0x00])
    }

    private static func writeRGB(_ payload: inout [UInt8], offset: Int, color: Int) {
        payload[offset] = UInt8(color & 0xFF)
        payload[offset + 1] = UInt8((color >> 8) & 0xFF)
        payload[offset + 2] = UInt8((color >> 16) & 0xFF)
    }
}
