import Foundation

/// DPI 档位下发（0x03）与复位（0x0C）。
public enum DpiCodec {
    public enum EncodeError: Error, Equatable {
        case badStageCount(Int)
    }

    /// `stageValues` 为各档 DPI（1...6），`currentIndex` 为 0-based 当前档。
    /// `buf[4]` 固定 0x25（原厂固定值，不是载荷长度）。
    public static func encodeStages(icType: UInt8, stageValues: [Int], currentIndex: Int) throws -> [UInt8] {
        guard (1...6).contains(stageValues.count) else {
            throw EncodeError.badStageCount(stageValues.count)
        }
        let count = stageValues.count
        var payload = [UInt8](repeating: 0, count: 1 + count * 4)
        payload[0] = UInt8(((currentIndex & 0x0F) << 4) | (count & 0x0F))
        for (i, dpi) in stageValues.enumerated() {
            let reg = DpiConversion.toRegister(icType: icType, dpi: dpi)
            let lo = UInt8(reg & 0xFF)
            let hi = UInt8(reg >> 8)
            let offset = 1 + i * 4
            payload[offset] = lo
            payload[offset + 1] = hi
            payload[offset + 2] = lo
            payload[offset + 3] = hi
        }
        return try MouseReport.build(command: 0x03, header: [0x00, 0x01, 0x25], payload: payload)
    }

    public static func encodeReset() throws -> [UInt8] {
        try MouseReport.build(command: 0x0C, header: [0x00, 0x01, 0x01], payload: [0x01])
    }
}
