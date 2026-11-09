import Foundation
import HIDProbeCore
import InphicMouseProtocol

// CLT-only 环境没有 XCTest（需要完整 Xcode），因此 Phase 1 用独立可执行自检。
// 运行: swift run probe-selftest  （失败时退出码 1）

struct Checker {
    var passed = 0
    var failures: [(name: String, detail: String)] = []

    mutating func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
        } else {
            failures.append((name, detail()))
        }
    }

    mutating func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        if actual == expected {
            passed += 1
        } else {
            failures.append((name, "expected \(expected), got \(actual)"))
        }
    }
}

func buildFrame(command: UInt8, header: [UInt8] = [], payload: [UInt8] = []) -> [UInt8] {
    do {
        return try MouseReport.build(command: command, header: header, payload: payload)
    } catch {
        fatalError("buildFrame 失败: \(error)")
    }
}

var c = Checker()

// 1. 0x10 请求帧
do {
    let frame = buildFrame(command: 0x10, header: [0x00, 0x01, 0x00])
    c.equal(frame.count, 33, "0x10 帧长度 33")
    c.equal(Array(frame[0...5]), [0x00, 0x10, 0x00, 0x01, 0x00, 0x00], "0x10 头部与载荷长度")
    c.equal(frame[32], 0x00, "0x10 校验和 0")
    c.check(MouseReport.verify(frame), "0x10 verify")
}

// 2. 上游 DpiCodecTests.EncodeStages_TwoStages_ByteExact 同一输入
do {
    let payload: [UInt8] = [0x02, 8, 0, 8, 0, 16, 0, 16, 0]
    let frame = buildFrame(command: 0x03, header: [0x00, 0x01, 0x25], payload: payload)
    c.equal(Array(frame[2...5]), [0x00, 0x01, 0x25, 0x02], "DPI header + 当前档/档数")
    c.equal(Array(frame[6..<14]), [8, 0, 8, 0, 16, 0, 16, 0], "DPI 两档寄存器 X/Y")
    c.equal(frame[32], 50, "DPI 校验和 50")
    c.check(MouseReport.verify(frame), "DPI verify")
}

// 3. 校验和回绕：0xFF + 0x02 → 0x01
c.equal(MouseReport.checksum([0, 0, 0, 0, 0, 0xFF, 0x02]), 0x01, "校验和 8 位回绕")

// 4. 头部不参与校验和
do {
    let a = buildFrame(command: 0x03, header: [0x00, 0x01, 0x25], payload: [0x10])
    let b = buildFrame(command: 0x05, header: [0x00, 0x01, 0x02], payload: [0x10])
    c.equal(a[32], b[32], "头部不参与校验和")
    c.equal(a[32], 0x10, "单字节载荷校验和")
}

// 5. 边界：header 最大 3、payload 最大 27
do {
    var threw = false
    do { _ = try MouseReport.build(command: 0x03, header: [0, 1, 2, 3]) } catch { threw = true }
    c.check(threw, "header 4 字节应抛错")

    threw = false
    do { _ = try MouseReport.build(command: 0x03, payload: [UInt8](repeating: 0, count: 28)) } catch { threw = true }
    c.check(threw, "payload 28 字节应抛错")

    threw = false
    do { _ = try MouseReport.build(command: 0x03, payload: [UInt8](repeating: 0, count: 27)) } catch { threw = true }
    c.check(!threw, "payload 27 字节应接受")
}

// 6. 0x10 解析（上游 DeviceInfoCodecTests 同一数据）
do {
    var bytes = [UInt8](repeating: 0, count: 0x10)
    bytes[8] = 0x02
    bytes[9] = 0x01
    bytes[0x0A] = 0x25
    bytes[0x0B] = 0x20
    bytes[0x0C] = 1
    bytes[0x0D] = 77
    bytes[0x0E] = 1

    if let info = DeviceInfoCodec.parse(bytes) {
        c.equal(info.firmwareVersion, 0x0102, "固件版本")
        c.equal(info.firmwareText, "1.02", "固件文本")
        c.equal(info.icType, 0x25, "ic_type")
        c.equal(info.reportRateMaxIndex, 6, "回报档上限")
        c.equal(info.isCharging, true, "充电标志")
        c.equal(info.batteryPercent, 77, "电量")
        c.equal(info.isOnline, true, "在线标志")
    } else {
        c.check(false, "0x10 解析应成功")
    }
    c.check(DeviceInfoCodec.parse([UInt8](repeating: 0, count: 5)) == nil, "短缓冲应返回 nil")

    var stripped = [UInt8](repeating: 0, count: 0x10)
    stripped[0] = 0x10
    stripped[2] = 0x01
    stripped[3] = 0x1B
    stripped[0x0A] = 0x11
    let withID = [0x00] + stripped
    if let a = DeviceInfoCodec.parseAnyOffset(stripped) {
        c.equal(a.offset, 0, "无 report ID 偏移 0")
        c.equal(a.info.icType, 0x11, "无 report ID ic_type")
    } else {
        c.check(false, "无 report ID 应解析")
    }
    if let b = DeviceInfoCodec.parseAnyOffset(withID) {
        c.equal(b.offset, 1, "含 report ID 偏移 1")
        c.equal(b.info.icType, 0x11, "含 report ID ic_type")
    } else {
        c.check(false, "含 report ID 应解析")
    }
}

// 7. ACK 偏移判定
c.equal(HIDDeviceSession.ackOffset(in: [0x10, 0x00, 0x01, 0x1B]), 0, "ACK 无 report ID")
c.equal(HIDDeviceSession.ackOffset(in: [0x00, 0x10, 0x00, 0x01, 0x1B]), 1, "ACK 含 report ID")
c.check(HIDDeviceSession.ackOffset(in: [0x10, 0x01, 0x00]) == nil, "非 ACK 不应误判")

// 8. 只读命令白名单：每条都是合法 33 字节帧，且不含写命令
for command in ReadCommand.allCases {
    let frame = command.frame
    c.equal(frame.count, 33, "\(command.title) 长度")
    c.equal(frame[1], command.rawValue, "\(command.title) 命令码")
    c.equal(frame[2], 0x00, "\(command.title) buf[2]")
    c.equal(frame[3], 0x01, "\(command.title) buf[3]")
    c.check(MouseReport.verify(frame), "\(command.title) verify")
}
c.check(ReadCommand(rawValue: 0x08) == nil, "0x08 写宏不在只读白名单")
c.check(ReadCommand(rawValue: 0x0C) == nil, "0x0C 复位不在只读白名单")

// 输出
for failure in c.failures {
    print("FAIL: \(failure.name) — \(failure.detail)")
}
print("\n\(c.passed) passed, \(c.failures.count) failed")
exit(c.failures.isEmpty ? 0 : 1)
