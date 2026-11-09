import Foundation
import InphicMouseProtocol

// CLT 环境没有 XCTest；用独立可执行程序校验协议层。
// 运行: swift run protocol-selftest  （失败时退出码 1）

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

nonisolated(unsafe) var c = Checker()

func expectThrows<T>(_ name: String, _ body: () throws -> T) {
    do {
        _ = try body()
        c.check(false, name, "应抛错但成功")
    } catch {
        c.check(true, name)
    }
}

// MARK: - MouseReport

func testMouseReport() throws {
    let frame = try MouseReport.build(command: 0x03, header: [0x00, 0x01, 0x25], payload: [0x02, 8, 0, 8, 0])
    c.equal(frame.count, 33, "帧长度 33")
    c.equal(Array(frame[0...5]), [0x00, 0x03, 0x00, 0x01, 0x25, 0x02], "帧头/载荷起点")
    c.equal(frame[32], 18, "校验和 18")
    c.check(MouseReport.verify(frame), "verify")

    let a = try MouseReport.build(command: 0x03, header: [0x00, 0x01, 0x25], payload: [0x10])
    let b = try MouseReport.build(command: 0x05, header: [0x00, 0x01, 0x02], payload: [0x10])
    c.equal(a[32], b[32], "头部不参与校验和")
    c.equal(a[32], 0x10, "单字节载荷校验和")

    let wrapped = try MouseReport.build(command: 0x03, header: [0x00, 0x01, 0x02], payload: [0xFF, 0x02])
    c.equal(wrapped[32], 0x01, "校验和 8 位回绕")

    expectThrows("header 4 字节拒绝") { try MouseReport.build(command: 0x03, header: [0, 1, 2, 3]) }
    expectThrows("payload 28 字节拒绝") { try MouseReport.build(command: 0x03, payload: [UInt8](repeating: 0, count: 28)) }
    _ = try MouseReport.build(command: 0x03, payload: [UInt8](repeating: 0, count: 27))
    c.check(true, "payload 27 字节接受")
}

// MARK: - DPI

func testDpi() throws {
    let frame = try DpiCodec.encodeStages(icType: 0x25, stageValues: [800, 1600], currentIndex: 0)
    c.equal(frame[1], 0x03, "DPI cmd")
    c.equal(Array(frame[2...5]), [0x00, 0x01, 0x25, 0x02], "DPI 头部/当前档/档数")
    c.equal(Array(frame[6..<10]), [8, 0, 8, 0], "DPI1 reg 8 X/Y")
    c.equal(Array(frame[10..<14]), [16, 0, 16, 0], "DPI2 reg 16 X/Y")
    c.check(MouseReport.verify(frame), "DPI verify")
    c.equal(frame[32], 50, "DPI 校验和 50")

    let three = try DpiCodec.encodeStages(icType: 0x25, stageValues: [800, 1600, 2400], currentIndex: 2)
    c.equal(three[5], (2 << 4) | 3, "当前档写入高半字节")

    expectThrows("DPI 0 档拒绝") { try DpiCodec.encodeStages(icType: 0x25, stageValues: [], currentIndex: 0) }
    expectThrows("DPI 7 档拒绝") { try DpiCodec.encodeStages(icType: 0x25, stageValues: [Int](repeating: 0, count: 7), currentIndex: 0) }

    let reset = try DpiCodec.encodeReset()
    c.equal(reset[1], 0x0C, "DPI reset cmd")
    c.equal(Array(reset[2...5]), [0x00, 0x01, 0x01, 0x01], "DPI reset 头/载荷")
}

// MARK: - Light

func testLight() throws {
    let solid = try LightCodec.encode(modeID: 3, brightness: 5, speed: 3, colors: [0x0000FF])
    c.equal(solid[1], 0x05, "灯光 cmd")
    c.equal(solid[4], 0x05, "常亮载荷长度 5")
    c.equal(solid[5], 3, "常亮模式 id")
    c.equal(solid[6], 0x53, "亮度/速度")
    c.equal(Array(solid[7..<10]), [0xFF, 0x00, 0x00], "常亮 RGB")
    c.check(MouseReport.verify(solid), "常亮 verify")

    let wave = try LightCodec.encode(modeID: 2, brightness: 15, speed: 0, colors: [1, 2, 3, 4, 5, 6, 7])
    c.equal(wave[4], 0x18, "七彩载荷长度 24")
    c.equal(wave[5], 2, "七彩模式 id")
    c.equal(wave[6], 0xF0, "七彩亮度/速度")
    c.equal(wave[7], 0x07, "七彩颜色数")
    c.equal(Array(wave[8..<11]), [1, 0, 0], "七彩首色")
    c.check(MouseReport.verify(wave), "七彩 verify")

    for mode in [0, 1, 4, 5] {
        let frame = try LightCodec.encode(modeID: mode, brightness: 8, speed: 2)
        c.equal(frame[1], 0x05, "模式 \(mode) cmd")
        c.equal(frame[4], mode == 1 ? 0x03 : 0x02, "模式 \(mode) 载荷长度")
        c.equal(frame[5], UInt8(mode), "模式 \(mode) id")
        c.equal(frame[6], 0x82, "模式 \(mode) 亮度/速度")
    }

    expectThrows("模式 2 缺 7 色拒绝") { try LightCodec.encode(modeID: 2, brightness: 0, speed: 0, colors: [1, 2, 3]) }
    expectThrows("模式 3 缺颜色拒绝") { try LightCodec.encode(modeID: 3, brightness: 0, speed: 0, colors: []) }
}

// MARK: - Settings

func testSettings() throws {
    let colors = try DeviceSettingsCodec.encodeDpiColors((0..<6).map { 0x030201 + $0 })
    c.equal(colors[1], 0x04, "DPI 颜色 cmd")
    c.equal(colors[4], 0x12, "DPI 颜色长度 18")
    c.equal(Array(colors[5..<8]), [0x01, 0x02, 0x03], "DPI 颜色首档")
    c.check(MouseReport.verify(colors), "DPI 颜色 verify")

    let sensor3 = try DeviceSettingsCodec.encodeSensorLift(liftoffHeight: 2, sensorFlag: 0x08)
    c.equal(sensor3[1], 0x06, "传感器 cmd")
    c.equal(Array(sensor3[5..<8]), [2, 1, 0], "传感器 bit3")
    let sensor2 = try DeviceSettingsCodec.encodeSensorLift(liftoffHeight: 0, sensorFlag: 0x04)
    c.equal(Array(sensor2[5..<8]), [0, 0, 1], "传感器 bit2")

    let sleep = try DeviceSettingsCodec.encodeSleep(sleepLight: 1, moveWakeup: 2, moveCloseLight: 3, buttonRespondTime: 4)
    c.equal(sleep[1], 0x07, "休眠 cmd")
    c.equal(Array(sleep[5..<9]), [1, 2, 3, 4], "休眠字段顺序")

    let rate = try DeviceSettingsCodec.encodeReportRate(2)
    c.equal(rate[1], 0x02, "回报率 cmd")
    c.equal(rate[4], 0x01, "回报率长度")
    c.equal(rate[5], 2, "回报率码")
}

// MARK: - DeviceInfo

func testDeviceInfo() throws {
    var bytes = [UInt8](repeating: 0, count: 0x10)
    bytes[8] = 0x02
    bytes[9] = 0x01
    bytes[0x0A] = 0x25
    bytes[0x0B] = 0x20
    bytes[0x0C] = 1
    bytes[0x0D] = 77
    bytes[0x0E] = 1

    let info = DeviceInfoCodec.parse(bytes)
    c.equal(info?.firmwareVersion, 0x0102, "固件版本")
    c.equal(info?.firmwareText, "1.02", "固件文本")
    c.equal(info?.icType, 0x25, "ic_type")
    c.equal(info?.reportRateMaxIndex, 6, "回报档上限")
    c.equal(info?.isCharging, true, "充电标志")
    c.equal(info?.batteryPercent, 77, "电量")
    c.equal(info?.isOnline, true, "在线标志")
    c.check(DeviceInfoCodec.parse([UInt8](repeating: 0, count: 5)) == nil, "短缓冲返回 nil")

    let request = try DeviceInfoCodec.encodeRequest()
    c.equal(request[1], 0x10, "设备信息请求 cmd")
    c.equal(request.count, 33, "设备信息请求长度")

    var stripped = [UInt8](repeating: 0, count: 0x10)
    stripped[0] = 0x10
    stripped[2] = 0x01
    stripped[3] = 0x1B
    stripped[0x0A] = 0x11
    let withID = [0x00] + stripped
    c.equal(DeviceInfoCodec.parseAnyOffset(stripped)?.offset, 0, "无 report ID 偏移")
    c.equal(DeviceInfoCodec.parseAnyOffset(withID)?.offset, 1, "含 report ID 偏移")
    c.equal(DeviceInfoCodec.parseAnyOffset(withID)?.info.icType, 0x11, "含 report ID ic_type")
}

// MARK: - KeyCodes / DPI conversion

func testKeyCodes() {
    let table: [(Int, UInt8)] = [
        (0x00, 0x00), (0xE0, 0x01), (0xA2, 0x01), (0xE1, 0x02), (0xA0, 0x02),
        (0xE2, 0x04), (0xE3, 0x08), (0x5B, 0x08), (0xE4, 0x10), (0xE5, 0x20),
        (0xE6, 0x40), (0xE7, 0x80), (0x5C, 0x80), (0x04, 0x04),
    ]
    for (usage, expected) in table {
        c.equal(KeyCodes.sysKeyCode(usage), expected, "sysKeyCode 0x\(String(usage, radix: 16))")
    }
    c.check(KeyCodes.isModifierUsage(0xE0), "0xE0 是修饰键")
    c.check(KeyCodes.isModifierUsage(0xE7), "0xE7 是修饰键")
    c.check(!KeyCodes.isModifierUsage(0xDF), "0xDF 不是修饰键")
    c.check(!KeyCodes.isModifierUsage(0x04), "0x04 不是修饰键")

    c.equal(KeyCodes.vkToHIDUsage(0x41), 0x04, "VK A → 0x04")
    c.equal(KeyCodes.vkToHIDUsage(0x30), 0x27, "VK 0 → 0x27")
    c.equal(KeyCodes.vkToHIDUsage(0x70), 0x3A, "VK F1 → 0x3A")
    c.equal(KeyCodes.vkToHIDUsage(0x60), 0x62, "VK Numpad0 → 0x62")
    c.equal(KeyCodes.vkToHIDUsage(0x0D), 0x28, "VK Enter → 0x28")
    c.equal(KeyCodes.vkToHIDUsage(0xFF), 0x00, "未覆盖 VK → 0")
}

func testDpiConversion() {
    let table: [(UInt8, Int, Int)] = [
        (0x11, 5000, 100), (0x11, 12000, 220), (0x11, 14000, 222),
        (0x05, 6400, 128), (0x05, 8000, 144),
        (0x25, 800, 8), (0x25, 6000, 52),
        (0x26, 100, 0), (0x26, 6000, 52),
        (0x31, 12000, 120), (0x31, 14000, 122),
        (0x04, 800, 8), (0x35, 1600, 16),
        (0x99, 800, 15),
    ]
    for (ic, dpi, expected) in table {
        c.equal(Int(DpiConversion.toRegister(icType: ic, dpi: dpi)), expected, "toRegister ic=0x\(String(ic, radix: 16)) dpi=\(dpi)")
    }
    c.equal(DpiConversion.clamp(10), 50, "DPI 下限")
    c.equal(DpiConversion.clamp(999_999), 26_000, "DPI 上限")
    c.equal(DpiConversion.clamp(1600), 1600, "DPI 原值")

    let roundTrip: [(UInt8, Int)] = [
        (0x11, 800), (0x11, 1600), (0x11, 6400), (0x11, 12000),
        (0x25, 800), (0x25, 6000), (0x05, 6400), (0x05, 8000),
        (0x31, 12000), (0x04, 4800),
    ]
    for (ic, dpi) in roundTrip {
        let reg = Int(DpiConversion.toRegister(icType: ic, dpi: dpi))
        c.equal(DpiConversion.fromRegister(icType: ic, register: reg), dpi, "DPI 往返 ic=0x\(String(ic, radix: 16)) dpi=\(dpi)")
    }
    c.equal(DpiConversion.fromRegister(icType: 0x11, register: 15), 750, "ic11 reg15 → 750")
    c.equal(DpiConversion.fromRegister(icType: 0x11, register: 31), 1550, "ic11 reg31 → 1550")
    c.equal(DpiConversion.fromRegister(icType: 0x11, register: 239), 12000, "ic11 reg239 → 12000")
}

// MARK: - KeyMap

func testKeyMap() throws {
    let defaultFrame = try KeyMapCodec.encodeDefault()
    c.equal(defaultFrame[1], 0x09, "默认映射 cmd")
    c.equal(defaultFrame[4], 0x0F, "默认映射长度 15")
    c.equal(Array(defaultFrame[5..<20]), KeyMapCodec.defaultPayload, "默认映射载荷")
    c.check(MouseReport.verify(defaultFrame), "默认映射 verify")

    let ctrlC = KeyMapCodec.KeyEntry.keyboard(usage: 0x06, modifierMask: 0x01)
    c.equal(ctrlC.type, 0x70, "Ctrl+C type")
    c.equal(ctrlC.v1, 0x01, "Ctrl+C 掩码")
    c.equal(ctrlC.v2, 0x06, "Ctrl+C usage")

    let lctrl = KeyMapCodec.KeyEntry.keyboard(usage: 0xE0, modifierMask: 0)
    c.equal(lctrl.v1, 0x01, "独立 LCtrl v1")
    c.equal(lctrl.v2, 0x00, "独立 LCtrl v2")

    let keys: [KeyMapCodec.KeyEntry] = [
        .mouse(0x01), .mouse(0x02), .system(), .keyboard(usage: 0x06, modifierMask: 0x01), .mouse(0x10),
    ]
    let frame = try KeyMapCodec.encode(keys)
    c.equal(Array(frame[5..<8]), [0x10, 0x01, 0x00], "5 键条目 1")
    c.equal(Array(frame[11..<14]), [0x60, 0x00, 0x00], "5 键条目 3")
    c.equal(Array(frame[14..<17]), [0x70, 0x01, 0x06], "5 键条目 4")
    c.check(MouseReport.verify(frame), "5 键 verify")

    expectThrows("0 键拒绝") { try KeyMapCodec.encode([]) }
    expectThrows("10 键拒绝") { try KeyMapCodec.encode([KeyMapCodec.KeyEntry](repeating: .mouse(1), count: 10)) }

    let six: [KeyMapCodec.KeyEntry] = [
        .mouse(0x01), .mouse(0x02), .mouse(0x04), .mouse(0x08), .mouse(0x10),
        .raw(type: 0x40, v1: 0x01, v2: 0x00),
    ]
    let sixFrame = try KeyMapCodec.encode(six)
    c.equal(sixFrame[4], 0x12, "6 键长度 18")
    c.equal(Array(sixFrame[20..<23]), [0x40, 0x01, 0x00], "6 键第 6 项")

    let playOnce = KeyMapCodec.KeyEntry.macro(5, repeatCount: 1)
    c.equal(playOnce.type, 0x90, "宏条目 type")
    c.equal(playOnce.v1, 0x26, "宏条目 v1（官方抓包）")
    c.equal(playOnce.v2, 0x01, "宏条目 v2（官方抓包）")

    let sixMacro: [KeyMapCodec.KeyEntry] = [
        .mouse(0x01), .mouse(0x02), .mouse(0x04), .mouse(0x08), .mouse(0x10),
        .macro(5, repeatCount: 1),
    ]
    let sixMacroFrame = try KeyMapCodec.encode(sixMacro)
    c.equal(Array(sixMacroFrame[20..<23]), [0x90, 0x26, 0x01], "6 键宏条目")

    c.equal(KeyMapCodec.KeyEntry.macro(0, repeatUntilRelease: true).v1 & 0xF0, 0x10, "按住循环标志")
    c.equal(KeyMapCodec.KeyEntry.macro(0, untilAnyKey: true).v1 & 0xF0, 0x40, "任意键停止标志")
    c.equal(KeyMapCodec.KeyEntry.macro(0, repeatCount: 3).v1 & 0xF0, 0x20, "指定次数标志")
    c.equal(KeyMapCodec.KeyEntry.macro(0).v1 & 0xF0, 0x00, "单次无标志")

    let rebound = KeyMapCodec.rebindMacroToKey(playOnce, keyIndex: 5)
    c.equal(rebound.v1, 0x26, "宏重定位 v1")
    c.equal(rebound.v2, 0x01, "宏重定位 v2")
    let held = KeyMapCodec.rebindMacroToKey(.macro(0, repeatUntilRelease: true), keyIndex: 2)
    c.equal(held.v1, 0x13, "按住循环重定位")
    let any = KeyMapCodec.rebindMacroToKey(.macro(0, untilAnyKey: true), keyIndex: 2)
    c.equal(any.v1, 0x43, "任意键停止重定位")

    let logical = KeyMapCodec.KeyEntry.macro(0, repeatCount: 1)
    let wire = KeyMapCodec.rebindMacroToKey(logical, keyIndex: 5)
    c.check(KeyMapCodec.macroEntryMatches(logical, logical), "宏条目匹配自身")
    c.check(KeyMapCodec.macroEntryMatches(wire, logical), "宏条目匹配重定位")
    c.check(!KeyMapCodec.macroEntryMatches(.mouse(0x01), logical), "鼠标条目不匹配宏")
    c.check(!KeyMapCodec.macroEntryMatches(logical, .mouse(0x01)), "宏条目不匹配鼠标")
}

// MARK: - Macro

func testMacro() throws {
    // 官方抓包：A↓ 50ms A↑，绑定 6 号键（key_code=5）。
    let frames = try MacroCodec.encode(macroSlot: 5, events: [
        .keyDown(0x41), .delay(50), .keyUp(0x41),
    ])
    c.equal(frames.count, 1, "官方抓包单帧")
    let frame = frames[0]
    let expected = [UInt8](repeating: 0, count: 33).enumerated().map { index, _ -> UInt8 in
        switch index {
        case 1: 0x08
        case 3: 0x01
        case 4: 0x09
        case 5: 0x06
        case 6: 0x30
        case 7: 0x32
        case 8: 0x00
        case 9: 0x04
        case 10: 0xB0
        case 11: 0x01
        case 12: 0x00
        case 13: 0x04
        case 32: 0x21
        default: 0x00
        }
    }
    c.equal(frame, expected, "官方抓包帧逐字节")
    c.check(MouseReport.verify(frame), "官方抓包 verify")
    c.equal(MouseReport.checksum(frame), 0x21, "官方抓包校验和")

    let click = try MacroCodec.encode(macroSlot: 0, events: [
        .mouseDown(1), .delay(50), .mouseUp(1),
    ])
    c.equal(click.count, 1, "鼠标点击单帧")
    c.equal(click[0][4], 0x09, "鼠标点击载荷长度")
    c.equal(click[0][5], 0x01, "鼠标点击槽 0+1")
    c.equal(Array(click[0][6..<10]), [0x10, 0x32, 0x00, 0x01], "左键按下 + 50ms")
    c.equal(Array(click[0][10..<14]), [0x90, 0x01, 0x00, 0x01], "左键松开最小 1ms")

    let modifier = try MacroCodec.encode(macroSlot: 0, events: [.keyDown(0xA2), .keyUp(0xA2)])
    c.equal(Array(modifier[0][6..<10]), [0x20, 0x01, 0x00, 0x01], "LCtrl 按下修饰 opcode")
    c.equal(Array(modifier[0][10..<14]), [0xA0, 0x01, 0x00, 0x01], "LCtrl 松开修饰 opcode")

    let ten = try MacroCodec.encode(macroSlot: 5, events: [
        .keyDown(0x41), .delay(50),
        .keyUp(0x41), .delay(1000),
        .mouseDown(1), .delay(50),
        .mouseUp(1),
        .mouseDown(4), .delay(50),
        .mouseUp(4),
    ])
    c.equal(ten.count, 1, "10 条记录折叠为单帧")
    c.equal(ten[0][5], 0x06, "10 条记录槽")
    c.equal(ten[0][4], 0x19, "10 条记录载荷长度 25")
    c.equal(Array(ten[0][6..<10]), [0x30, 0x32, 0x00, 0x04], "折叠动作 1")
    c.equal(Array(ten[0][10..<14]), [0xB0, 0xE8, 0x03, 0x04], "折叠动作 2 延时 1000")
    c.equal(Array(ten[0][14..<18]), [0x10, 0x32, 0x00, 0x01], "折叠动作 3")
    c.equal(Array(ten[0][18..<22]), [0x90, 0x01, 0x00, 0x01], "折叠动作 4")
    c.equal(Array(ten[0][22..<26]), [0x10, 0x32, 0x00, 0x04], "折叠动作 5")
    c.equal(Array(ten[0][26..<30]), [0x90, 0x01, 0x00, 0x04], "折叠动作 6")

    // 末尾延时并入最后一个动作。
    let trailing = try MacroCodec.encode(macroSlot: 0, events: [.keyDown(0x41), .delay(100)])
    c.equal(Array(trailing[0][6..<10]), [0x30, 0x64, 0x00, 0x04], "末尾延时并入前一动作")

    // 相邻动作最小 1ms。
    let adjacent = try MacroCodec.encode(macroSlot: 0, events: [.keyDown(0x41), .keyUp(0x41)])
    c.equal(Array(adjacent[0][6..<10]), [0x30, 0x01, 0x00, 0x04], "相邻动作默认 1ms")

    // 8 动作分块：body = 1 + 32 = 33 → 27 + 6。
    let eight = (0..<4).flatMap { _ in [MacroCodec.MacroEvent.keyDown(0x41), MacroCodec.MacroEvent.keyUp(0x41)] }
    let chunks = try MacroCodec.encode(macroSlot: 1, events: eight)
    c.equal(chunks.count, 2, "8 动作分为 2 块")
    c.equal(chunks[0][3], 0x02, "块 0 头：总块数 2")
    c.equal(chunks[0][4], 0x1B, "块 0 长度 27")
    c.equal(chunks[1][3], 0x12, "块 1 头：块序 1 + 总块数 2")
    c.equal(chunks[1][4], 0x06, "块 1 长度 6")
    var reassembled: [UInt8] = []
    for chunk in chunks {
        let length = Int(chunk[4])
        reassembled.append(contentsOf: chunk[5..<(5 + length)])
    }
    c.equal(reassembled.count, 33, "分块重组长度 33")
    c.equal(reassembled[0], 0x02, "分块体重组槽 1+1")
    c.check(chunks.allSatisfy { MouseReport.verify($0) }, "所有分块校验和有效")

    // 块数超过 15 → 明确抛错，避免头字节溢出。
    let tooMany = [MacroCodec.MacroEvent](repeating: .keyDown(0x41), count: 103)
    expectThrows("超过 15 块拒绝") { try MacroCodec.encode(macroSlot: 0, events: tooMany) }
}

// MARK: - Run

do {
    try testMouseReport()
    try testDpi()
    try testLight()
    try testSettings()
    try testDeviceInfo()
    testKeyCodes()
    testDpiConversion()
    try testKeyMap()
    try testMacro()
} catch {
    c.check(false, "unexpected error", "\(error)")
}

for failure in c.failures {
    print("FAIL: \(failure.name) — \(failure.detail)")
}
print("\n\(c.passed) passed, \(c.failures.count) failed")
exit(c.failures.isEmpty ? 0 : 1)
