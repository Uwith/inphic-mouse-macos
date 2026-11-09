import Foundation
import HIDProbeCore
import InphicMouseProtocol
import IOKit

// Phase 3 宏上传工具（默认只读 / 只打印计划）。
// 写入必须显式 `apply --yes`，且会先自动备份当前可读配置。
// 警告：宏内容无法从设备读回（0x18 无响应），覆盖后不可恢复。

struct Options {
    var command = "plan"
    var index: Int?
    var key = 5
    var slot: Int?
    var backupPath: String?
    var yes = false
    var timeout: TimeInterval = 2.0
    var sets: [(index: Int, entry: KeyMapCodec.KeyEntry)] = []
}

func usage() {
    print("""
    InphicMouse macro-tool（Phase 3）

    用法:
      macro-tool backup [--index N] [--out FILE]   读取 0x10-0x17/0x20 并保存 JSON
      macro-tool plan   [--index N] [--key K]      只读：打印宏帧与将要写入的按键映射
      macro-tool apply  [--index N] [--key K] --yes
                                                   备份 → 写 0x08 → 写 0x09 → 读回 0x11
      macro-tool restore --backup FILE --yes       用备份中的 0x11 载荷恢复按键映射
      macro-tool set-key --set K=HHHHHH [--set ...] [--yes]
                                                   只改按键映射：K=键下标，HHHHHH=3 字节条目
                                                   例：--set 3=700150 --set 4=70014F（Ctrl+←/→）

    说明:
      --key K   物理键下标（0-based，默认 5 = 0x11 读到的第 6 个键 / DPI 键）
      --slot S  宏槽，默认等于 --key（官方约定：宏槽 = 键下标）
      只写一个测试宏：按下 A → 延时 100ms → 松开 A，循环 1 次
      宏内容不可读回；写入覆盖后无法从设备恢复
    """)
}

func parseHexInt(_ text: String) -> Int? {
    var value = text.lowercased()
    if value.hasPrefix("0x") { value.removeFirst(2) }
    return Int(value, radix: 16)
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    if let first = args.first, !first.hasPrefix("-") {
        options.command = first
        args.removeFirst()
    }
    var i = 0
    while i < args.count {
        let arg = args[i]
        func next() -> String? {
            guard i + 1 < args.count else { return nil }
            i += 1
            return args[i]
        }
        switch arg {
        case "-h", "--help": usage(); exit(0)
        case "--index": options.index = next().flatMap(Int.init)
        case "--key": options.key = next().flatMap(Int.init) ?? options.key
        case "--slot": options.slot = next().flatMap(Int.init)
        case "--backup": options.backupPath = next()
        case "--out": options.backupPath = next()
        case "--set":
            guard let spec = next() else { print("错误: --set 需要 K=HHHHHH"); exit(4) }
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let index = Int(parts[0]),
                  let raw = parseHexInt(parts[1]), (0...0xFF_FFFF).contains(raw) else {
                print("错误: --set 格式应为 K=HHHHHH，例如 3=700150"); exit(4)
            }
            let entry = KeyMapCodec.KeyEntry(
                type: UInt8((raw >> 16) & 0xFF),
                v1: UInt8((raw >> 8) & 0xFF),
                v2: UInt8(raw & 0xFF)
            )
            options.sets.append((index, entry))
        case "--timeout-ms": if let v = next().flatMap(Double.init) { options.timeout = v / 1000 }
        case "--yes": options.yes = true
        default:
            print("错误: 未知参数 \(arg)"); usage(); exit(4)
        }
        i += 1
    }
    return options
}

func selectTarget(_ entries: [(info: HIDDeviceInfo, device: IOHIDDevice)], index: Int?) throws -> (info: HIDDeviceInfo, device: IOHIDDevice) {
    if let index {
        guard entries.indices.contains(index) else { throw ToolError("--index \(index) 超出范围 0..<\(entries.count)") }
        return entries[index]
    }
    let candidates = entries.filter { $0.info.isInphic && $0.info.interfaceNumber == InphicHardware.configInterfaceNumber }
    guard candidates.count == 1 else {
        throw ToolError("找到 \(candidates.count) 个 INPHIC 接口 2 候选，请用 --index 指定；先运行 hid-probe list")
    }
    return candidates[0]
}

struct ToolError: Error, CustomStringConvertible {
    var message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: - 备份

struct BackupRecord: Codable {
    var command: String
    var title: String
    var sentHex: String
    var responsesHex: [String]
    var ack: Bool
    var ackOffset: Int?
}

struct BackupFile: Codable {
    var savedAt: String
    var vendorID: Int
    var productID: Int
    var product: String
    var serialNumber: String
    var interfaceNumber: Int?
    var records: [BackupRecord]
}

func readAllConfiguration(session: HIDDeviceSession, timeout: TimeInterval) -> [BackupRecord] {
    ReadCommand.allCases.map { command in
        let result = session.exchange(frame: command.frame, mode: .strip, timeout: timeout)
        return BackupRecord(
            command: String(format: "0x%02X", command.rawValue),
            title: command.title,
            sentHex: Hex.string(result.wireBytes),
            responsesHex: result.responses.map(Hex.string),
            ack: result.acked,
            ackOffset: result.ackOffset
        )
    }
}

func writeBackup(_ backup: BackupFile, path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(backup)
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func defaultBackupPath() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "backups/inphic-\(formatter.string(from: Date())).json"
}

@discardableResult
func saveBackup(session: HIDDeviceSession, options: Options) throws -> String {
    let records = readAllConfiguration(session: session, timeout: options.timeout)
    let path = options.backupPath ?? defaultBackupPath()
    let info = session.info
    try writeBackup(BackupFile(
        savedAt: ISO8601DateFormatter().string(from: Date()),
        vendorID: info.vendorID, productID: info.productID,
        product: info.product, serialNumber: info.serialNumber,
        interfaceNumber: info.interfaceNumber, records: records
    ), path: path)
    return path
}

// MARK: - 按键映射

func readKeyMap(session: HIDDeviceSession, timeout: TimeInterval) -> [KeyMapCodec.KeyEntry]? {
    // 0x11 偶发首帧无响应（设备刚唤醒/会话刚打开），重试 3 次。
    for attempt in 0..<3 {
        if let entries = readKeyMapOnce(session: session, timeout: timeout) { return entries }
        if attempt < 2 { usleep(150_000) }
    }
    return nil
}

private func readKeyMapOnce(session: HIDDeviceSession, timeout: TimeInterval) -> [KeyMapCodec.KeyEntry]? {
    let result = session.exchange(frame: ReadCommand.handshake.frame, mode: .strip, timeout: timeout)
    guard let response = result.ackResponse else { return nil }
    let offset = result.ackOffset ?? 0
    guard response.count >= offset + 4 else { return nil }
    let length = Int(response[offset + 3])
    let start = offset + 4
    guard length > 0, length % 3 == 0, start + length <= response.count else { return nil }
    var entries: [KeyMapCodec.KeyEntry] = []
    for i in stride(from: 0, to: length, by: 3) {
        entries.append(.init(type: response[start + i], v1: response[start + i + 1], v2: response[start + i + 2]))
    }
    return entries
}

func describe(_ entry: KeyMapCodec.KeyEntry) -> String {
    String(format: "type=0x%02X v1=0x%02X v2=0x%02X", entry.type, entry.v1, entry.v2)
}

// MARK: - 命令

func withSession(_ options: Options, _ body: (HIDDeviceSession) throws -> Int32) -> Int32 {
    do {
        let entries = try HIDEnumerator().entries()
        let target = try selectTarget(entries, index: options.index)
        let session = HIDDeviceSession(device: target.device, info: target.info)
        let open = session.open()
        guard open == kIOReturnSuccess else {
            throw ToolError("打开失败: \(HIDEnumeratorError.returnText(open))；请用 hid-probe list 确认接口 2")
        }
        defer { session.close() }
        print("目标: \(target.info.oneLine)")
        return try body(session)
    } catch {
        print("错误: \(error)")
        return 4
    }
}

func runBackup(_ options: Options) -> Int32 {
    withSession(options) { session in
        let records = readAllConfiguration(session: session, timeout: options.timeout)
        let path = options.backupPath ?? defaultBackupPath()
        let info = session.info
        let backup = BackupFile(
            savedAt: ISO8601DateFormatter().string(from: Date()),
            vendorID: info.vendorID, productID: info.productID,
            product: info.product, serialNumber: info.serialNumber,
            interfaceNumber: info.interfaceNumber, records: records
        )
        try writeBackup(backup, path: path)
        for record in records {
            print("\(record.title): ack=\(record.ack)  \(record.responsesHex.last ?? "(无响应)")")
        }
        print("\n备份已写入: \(path)")
        print("注意: 0x11 是按键映射；宏内容本身无法读回。")
        return 0
    }
}

func runPlan(_ options: Options) -> Int32 {
    withSession(options) { session in
        guard let entries = readKeyMap(session: session, timeout: options.timeout) else {
            throw ToolError("0x11 未返回可解析的按键映射")
        }
        guard entries.count == 6 else {
            throw ToolError("0x11 返回 \(entries.count) 个键，本工具按 6 键处理")
        }
        guard (0...5).contains(options.key) else { throw ToolError("--key 必须在 0...5") }
        let slot = options.slot ?? options.key
        guard (0...5).contains(slot) else { throw ToolError("--slot 必须在 0...5") }

        let events: [MacroCodec.MacroEvent] = [.keyDown(0x41), .delay(100), .keyUp(0x41)]
        let macroFrames = try MacroCodec.encode(macroSlot: slot, events: events)

        var newEntries = entries
        newEntries[options.key] = .macro(slot, repeatCount: 1)
        let keyMapFrame = try KeyMapCodec.encode(newEntries)

        print("\n当前按键映射:")
        for (i, entry) in entries.enumerated() { print("  [\(i)] \(describe(entry))") }
        print("\n宏（槽 \(slot)，绑定键 \(options.key)）:")
        for (i, frame) in macroFrames.enumerated() {
            print("  0x08 帧#\(i): \(Hex.string(frame))")
        }
        print("\n新按键映射 0x09: \(Hex.string(keyMapFrame))")
        print("  键 \(options.key): \(describe(entries[options.key])) → \(describe(newEntries[options.key]))")
        print("\n以上为 dry-run，未写入。")
        return 0
    }
}

func runApply(_ options: Options) -> Int32 {
    guard options.yes else {
        print("拒绝写入：apply 需要 --yes。先运行 `macro-tool plan` 查看将要发送的帧。")
        return 2
    }
    return withSession(options) { session in
        guard let oldEntries = readKeyMap(session: session, timeout: options.timeout) else {
            throw ToolError("0x11 未返回可解析的按键映射；未写入")
        }
        guard oldEntries.count == 6 else { throw ToolError("0x11 返回 \(oldEntries.count) 个键；未写入") }
        guard (0...5).contains(options.key) else { throw ToolError("--key 必须在 0...5") }
        let slot = options.slot ?? options.key
        guard (0...5).contains(slot) else { throw ToolError("--slot 必须在 0...5") }

        // 1. 先备份全部可读配置。
        let records = readAllConfiguration(session: session, timeout: options.timeout)
        let path = options.backupPath ?? defaultBackupPath()
        let info = session.info
        try writeBackup(BackupFile(
            savedAt: ISO8601DateFormatter().string(from: Date()),
            vendorID: info.vendorID, productID: info.productID,
            product: info.product, serialNumber: info.serialNumber,
            interfaceNumber: info.interfaceNumber, records: records
        ), path: path)
        print("已备份: \(path)")

        // 2. 写宏内容 0x08，逐帧要求 ACK。
        let events: [MacroCodec.MacroEvent] = [.keyDown(0x41), .delay(100), .keyUp(0x41)]
        let frames = try MacroCodec.encode(macroSlot: slot, events: events)
        for (i, frame) in frames.enumerated() {
            let result = session.exchange(frame: frame, mode: .strip, timeout: options.timeout)
            print("0x08 #\(i): write=\(result.wrote) ack=\(result.acked) sent=\(Hex.string(result.wireBytes))")
            guard result.wrote else { throw ToolError("0x08 第 \(i) 帧写失败；未写按键映射") }
            guard result.acked else {
                throw ToolError("0x08 第 \(i) 帧写成功但没有 ACK；未写按键映射。设备可能已收到部分宏，请重新运行并观察。")
            }
        }

        // 3. 写按键映射 0x09。
        var newEntries = oldEntries
        newEntries[options.key] = .macro(slot, repeatCount: 1)
        let keyMapFrame = try KeyMapCodec.encode(newEntries)
        let keyMapResult = session.exchange(frame: keyMapFrame, mode: .strip, timeout: options.timeout)
        print("0x09: write=\(keyMapResult.wrote) ack=\(keyMapResult.acked) sent=\(Hex.string(keyMapResult.wireBytes))")
        guard keyMapResult.wrote else { throw ToolError("0x09 写失败") }

        // 4. 读回 0x11 验证按键映射。
        guard let readBack = readKeyMap(session: session, timeout: options.timeout) else {
            print("读回: 0x11 无有效响应（写入结果未知）")
            return 1
        }
        let matched = readBack.count == newEntries.count && zip(readBack, newEntries).allSatisfy { $0 == $1 }
        print("读回 0x11: \(matched ? "与目标一致" : "与目标不一致")")
        for (i, entry) in readBack.enumerated() { print("  [\(i)] \(describe(entry))") }

        print("""

        写入状态（四态，不得混淆）:
          发送: 成功
          ACK : \(keyMapResult.acked ? "收到" : "未收到")
          读回: \(matched ? "一致" : "不一致/未知")
          执行: 未验证 —— 请手动按下键 \(options.key)，确认是否输入 A

        恢复按键映射: macro-tool restore --backup \(path) --yes
        警告: 宏内容无法读回；若按键未触发，槽 \(slot) 的旧宏已不可恢复。
        """)
        return matched ? 0 : 1
    }
}

func runSetKey(_ options: Options) -> Int32 {
    guard !options.sets.isEmpty else {
        print("错误: set-key 需要至少一个 --set K=HHHHHH")
        return 4
    }
    return withSession(options) { session in
        guard var entries = readKeyMap(session: session, timeout: options.timeout) else {
            throw ToolError("0x11 未返回可解析的按键映射；未写入")
        }
        guard entries.count == 6 else { throw ToolError("0x11 返回 \(entries.count) 个键；未写入") }

        print("\n当前按键映射:")
        for (i, entry) in entries.enumerated() { print("  [\(i)] \(describe(entry))") }

        var changes: [(Int, KeyMapCodec.KeyEntry, KeyMapCodec.KeyEntry)] = []
        for (index, entry) in options.sets {
            guard entries.indices.contains(index) else {
                throw ToolError("--set 键下标 \(index) 超出 0..<\(entries.count)")
            }
            changes.append((index, entries[index], entry))
            entries[index] = entry
        }

        let frame = try KeyMapCodec.encode(entries)
        print("\n修改:")
        for (index, old, new) in changes {
            print("  [\(index)] \(describe(old)) → \(describe(new))")
        }
        print("\n新按键映射 0x09: \(Hex.string(frame))")

        guard options.yes else {
            print("\n以上为 dry-run，未写入。")
            return 0
        }

        let path = try saveBackup(session: session, options: options)
        print("\n已备份: \(path)")

        let result = session.exchange(frame: frame, mode: .strip, timeout: options.timeout)
        print("0x09: write=\(result.wrote) ack=\(result.acked) sent=\(Hex.string(result.wireBytes))")
        guard result.wrote else { throw ToolError("0x09 写失败") }

        guard let readBack = readKeyMap(session: session, timeout: options.timeout) else {
            print("读回: 0x11 无有效响应（写入结果未知）")
            return 1
        }
        let matched = readBack.count == entries.count && zip(readBack, entries).allSatisfy { $0 == $1 }
        print("读回 0x11: \(matched ? "与目标一致" : "与目标不一致")")
        for (i, entry) in readBack.enumerated() { print("  [\(i)] \(describe(entry))") }

        print("""

        写入状态（四态，不得混淆）:
          发送: 成功
          ACK : \(result.acked ? "收到" : "未收到")
          读回: \(matched ? "一致" : "不一致/未知")
          执行: 未验证 —— 请手动按下被修改的键，确认系统动作

        恢复按键映射: macro-tool restore --backup \(path) --yes
        """)
        return matched ? 0 : 1
    }
}

func runRestore(_ options: Options) -> Int32 {
    guard options.yes else {
        print("拒绝写入：restore 需要 --yes。")
        return 2
    }
    guard let path = options.backupPath else {
        print("错误: restore 需要 --backup FILE")
        return 4
    }
    return withSession(options) { session in
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let backup = try JSONDecoder().decode(BackupFile.self, from: data)
        guard let record = backup.records.first(where: { $0.command == "0x11" }),
              let hex = record.responsesHex.first else {
            throw ToolError("备份中没有 0x11 响应")
        }
        let bytes = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard bytes.count >= 4 else { throw ToolError("备份 0x11 响应过短") }
        let offset = record.ackOffset ?? 0
        let length = Int(bytes[offset + 3])
        let start = offset + 4
        guard length > 0, length % 3 == 0, start + length <= bytes.count else {
            throw ToolError("备份 0x11 载荷长度无效")
        }
        var entries: [KeyMapCodec.KeyEntry] = []
        for i in stride(from: 0, to: length, by: 3) {
            entries.append(.init(type: bytes[start + i], v1: bytes[start + i + 1], v2: bytes[start + i + 2]))
        }
        let frame = try KeyMapCodec.encode(entries)
        let result = session.exchange(frame: frame, mode: .strip, timeout: options.timeout)
        print("0x09 restore: write=\(result.wrote) ack=\(result.acked)")
        print("发送: \(Hex.string(result.wireBytes))")
        return result.wrote ? 0 : 1
    }
}

// MARK: - main

let options = parseOptions()
print("=== InphicMouse macro-tool (Phase 3) ===\n")
let code: Int32
switch options.command {
case "backup": code = runBackup(options)
case "plan": code = runPlan(options)
case "apply": code = runApply(options)
case "set-key": code = runSetKey(options)
case "restore": code = runRestore(options)
default:
    usage()
    code = 4
}
exit(code)
