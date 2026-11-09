import Foundation
import HIDProbeCore
import IOKit

// InphicMouse macOS HID Probe — Phase 1
// 只发送协议文档已确认的只读命令；拒绝写入/复位/未知命令。

struct Options {
    var command = "list"
    var index: Int?
    var vid: Int?
    var pid: Int?
    var interfaceNumber: Int?
    var timeout: TimeInterval = 1.0
    var reportMode: ReportIDMode = .strip
    var commands: [ReadCommand] = [.deviceInfo, .reportRate, .dpi, .light]
    var seconds: TimeInterval = 30
    var repeatCount = 1
    var inphicOnly = false
    var exitAfterList = false
}

func usage() {
    print("""
    InphicMouse macOS HID Probe (Phase 1)

    用法:
      hid-probe list [--inphic]                     枚举全部 HID 接口
      hid-probe probe [选项]                        打开 IN9 配置接口并执行只读命令
      hid-probe monitor [--seconds N]               监听 HID 插入/移除

    probe 选项:
      --index N             使用 list 列表中的第 N 个接口
      --vid 0x248A          过滤 VID（默认自动 248A/249A）
      --pid 0x8266          过滤 PID（默认 8266）
      --interface 2         接口号（默认优先 bInterfaceNumber==2）
      --timeout-ms 1000     每次交换总超时
      --report-id strip|keep
                            strip: 发送 32 字节（ID 单独传入，默认）
                            keep : 原样发送 33 字节
      --commands 0x10,0x12,0x13,0x15
                            只读命令白名单：0x10-0x17, 0x20
      --repeat N            重复 0x10 N 次，统计 ACK 成功率
      --list                打印列表后继续 probe
      -h, --help            显示帮助

    退出码: 0 有 ACK / 2 未找到设备 / 3 已打开但无 ACK / 4 参数或打开失败
    """)
}

func parseHex(_ text: String) -> Int? {
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
        case "-h", "--help":
            usage()
            exit(0)
        case "--index":
            options.index = next().flatMap(Int.init)
        case "--vid":
            options.vid = next().flatMap(parseHex)
        case "--pid":
            options.pid = next().flatMap(parseHex)
        case "--interface":
            options.interfaceNumber = next().flatMap(Int.init)
        case "--timeout-ms":
            if let value = next().flatMap(Double.init) { options.timeout = value / 1000.0 }
        case "--report-id":
            if let value = next().flatMap(ReportIDMode.init(rawValue:)) { options.reportMode = value }
        case "--commands":
            if let value = next() {
                let values = value.split(separator: ",").compactMap { parseHex(String($0)) }
                let allowed = values.compactMap { ReadCommand(rawValue: UInt8($0)) }
                if allowed.count != values.count {
                    print("错误: --commands 只允许 \(ReadCommand.allCases.map { String(format: "0x%02X", $0.rawValue) }.joined(separator: ","))")
                    exit(4)
                }
                options.commands = allowed
            }
        case "--repeat":
            options.repeatCount = max(1, next().flatMap(Int.init) ?? 1)
        case "--seconds":
            options.seconds = max(1, next().flatMap(Double.init) ?? 30)
        case "--inphic":
            options.inphicOnly = true
        case "--list":
            options.exitAfterList = true
        default:
            print("错误: 未知参数 \(arg)")
            usage()
            exit(4)
        }
        i += 1
    }
    return options
}

func printDeviceList(_ devices: [HIDDeviceInfo], inphicOnly: Bool) {
    let shown = inphicOnly ? devices.filter(\.isInphic) : devices
    print("共枚举 \(devices.count) 个 HID 接口\(inphicOnly ? "（显示 INPHIC \(shown.count) 个）" : "")：\n")
    for info in shown {
        print(info.oneLine)
        let iface = info.interfaceNumber.map(String.init) ?? "未知"
        print("      product=\"\(info.product)\"  manufacturer=\"\(info.manufacturer)\"  if=\(iface)")
    }
    if devices.contains(where: \.isInphic) {
        print("\nINPHIC 厂商候选（VID 0x248A/0x249A）：")
        for info in devices where info.isInphic {
            print("  \(info.oneLine)")
        }
    } else {
        print("\n未发现 INPHIC 厂商设备（VID 0x248A/0x249A）。")
        print("请确认：有线连接 / 2.4G 接收器已插好 / 鼠标未休眠。")
    }
}

func selectTarget(
    _ entries: [(info: HIDDeviceInfo, device: IOHIDDevice)],
    options: Options
) -> (info: HIDDeviceInfo, device: IOHIDDevice)? {
    if let index = options.index {
        guard entries.indices.contains(index) else {
            print("错误: --index \(index) 超出范围 0..<\(entries.count)")
            return nil
        }
        return entries[index]
    }

    var candidates = entries.filter { $0.info.isInphic }
    if let vid = options.vid { candidates = candidates.filter { $0.info.vendorID == vid } }
    if let pid = options.pid { candidates = candidates.filter { $0.info.productID == pid } }

    if let iface = options.interfaceNumber {
        let exact = candidates.filter { $0.info.interfaceNumber == iface }
        if exact.count == 1 { return exact[0] }
        if exact.isEmpty {
            print("错误: 没有 bInterfaceNumber==\(iface) 的 INPHIC 接口。请用 list 查看并用 --index 指定。")
        } else {
            print("错误: 有 \(exact.count) 个接口号 \(iface) 的候选，请用 --index 指定。")
        }
        return nil
    }

    let preferred = candidates.filter(\.info.isLikelyConfigurationInterface)
    if preferred.count == 1 {
        let target = preferred[0]
        if !target.info.hasUpstreamPID {
            print("警告: PID=0x\(String(format: "%04X", target.info.productID)) 与上游记录的 0x8266 不同。")
            print("      这是实机发现的变体（见 docs/STATUS.md），协议读取已能工作，但型号/写入行为仍需逐项验证。")
        }
        return target
    }
    if preferred.count > 1 {
        print("错误: 有 \(preferred.count) 个 bInterfaceNumber==2 的候选，请用 --index 指定：")
        for row in preferred { print("  \(row.info.oneLine)") }
        return nil
    }
    if candidates.count == 1 {
        print("警告: 未找到 bInterfaceNumber==2，暂用唯一候选。若通信失败，请用 --index 明确指定。")
        return candidates[0]
    }
    if candidates.isEmpty {
        print("错误: 未找到 INPHIC 设备（VID 0x248A/0x249A, PID 0x8266）。")
    } else {
        print("错误: 发现 \(candidates.count) 个 INPHIC 候选，但都不是接口 2。请用 --index 指定：")
        for row in candidates { print("  \(row.info.oneLine)") }
    }
    return nil
}

func payloadSlice(_ bytes: [UInt8], ackOffset: Int?) -> [UInt8]? {
    let off = ackOffset ?? 0
    guard bytes.count >= off + 4 else { return nil }
    let length = Int(bytes[off + 3])
    let start = off + 4
    guard length > 0, start + length <= bytes.count else { return nil }
    return Array(bytes[start..<(start + length)])
}

func decode(command: ReadCommand, response: [UInt8]?, ackOffset: Int?) {
    guard let response, !response.isEmpty else {
        print("  解码    : (无响应)")
        return
    }
    switch command {
    case .deviceInfo:
        if let (offset, info) = DeviceInfoCodec.parseAnyOffset(response) {
            print("  解码[+\(offset)]: 固件=\(info.firmwareText)  IC=0x\(String(format: "%02X", info.icType))  电量=\(info.batteryPercent)%  充电=\(info.isCharging)  在线=\(info.isOnline)  回报档上限=\(info.reportRateMaxIndex)")
        } else {
            print("  解码    : 响应长度不足 0x0F，无法解析（原始字节见上）")
        }
    case .reportRate:
        guard let p = payloadSlice(response, ackOffset: ackOffset), !p.isEmpty else { return }
        print("  解码    : 回报率档位码 = \(p[0])（1↔1000Hz / 2↔500 / 4↔250 / 8↔125，待实机确认）")
    case .dpi:
        guard let p = payloadSlice(response, ackOffset: ackOffset), let first = p.first else { return }
        let current = Int(first >> 4), count = Int(first & 0x0F)
        print("  解码    : 当前档=\(current + 1)  档数=\(count)")
        for k in 0..<min(count, 6) {
            let offset = 1 + k * 4
            guard offset + 1 < p.count else { break }
            let reg = Int(p[offset]) | Int(p[offset + 1]) << 8
            print("            DPI\(k + 1): reg=\(reg)  lo=0x\(String(format: "%02X", p[offset])) hi=0x\(String(format: "%02X", p[offset + 1]))")
        }
    case .light:
        guard let p = payloadSlice(response, ackOffset: ackOffset), !p.isEmpty else { return }
        print("  解码    : 灯光模式 id = \(p[0])")
        if p.count > 1 {
            print("            亮度 = \(p[1] >> 4)  速度 = \(p[1] & 0x0F)")
        }
    case .sensor:
        guard let p = payloadSlice(response, ackOffset: ackOffset), p.count >= 3 else { return }
        print("  解码    : 抬升高度=\(p[0])  sensor bit3=\(p[1])  bit2=\(p[2])")
    case .sleep:
        guard let p = payloadSlice(response, ackOffset: ackOffset), p.count >= 4 else { return }
        print("  解码    : 休眠原始值=\(p[0])（≈\(p[0] / 6) 分钟） 移动唤醒=\(p[1]) 移动关灯=\(p[2]) 按键响应=\(p[3])")
    case .wirelessFirmware:
        guard let p = payloadSlice(response, ackOffset: ackOffset), p.count >= 4 else { return }
        let fw = UInt16(p[3]) << 8 | UInt16(p[2])
        print("  解码    : 无线固件 = 0x\(String(format: "%04X", fw))")
    case .handshake:
        print("  解码    : 握手响应（不解析）")
    case .dpiColor:
        guard let p = payloadSlice(response, ackOffset: ackOffset) else { return }
        print("  解码    : DPI 颜色原始载荷 = \(Hex.string(p))")
    }
}

func runProbe(options: Options) -> Int32 {
    let entries: [(info: HIDDeviceInfo, device: IOHIDDevice)]
    do {
        entries = try HIDEnumerator().entries()
    } catch {
        print("错误: \(error)")
        return 4
    }

    if options.command == "list" || options.exitAfterList {
        printDeviceList(entries.map(\.info), inphicOnly: options.inphicOnly)
        if options.command == "list" { return 0 }
        print()
    }

    guard let target = selectTarget(entries, options: options) else { return 2 }

    print(">>> 目标 [\(target.info.index)] \(target.info.oneLine)")
    print("    product=\"\(target.info.product)\"  manufacturer=\"\(target.info.manufacturer)\"")
    print("    serial=\"\(target.info.serialNumber)\"  interface=\(target.info.interfaceNumber.map(String.init) ?? "未知")")
    print("    report sizes: in=\(target.info.maxInputReportSize) out=\(target.info.maxOutputReportSize) feature=\(target.info.maxFeatureReportSize)")

    let session = HIDDeviceSession(device: target.device, info: target.info)
    let openResult = session.open()
    print("    打开: \(HIDEnumeratorError.returnText(openResult))")
    guard openResult == kIOReturnSuccess else {
        print("错误: 无法打开接口。若为 kIOReturnExclusiveAccess，说明该 collection 被系统占用；")
        print("      请确认选择的是厂商配置接口（bInterfaceNumber==2），而不是鼠标输入接口。")
        return 4
    }
    defer { session.close() }

    var anyAck = false
    for command in options.commands {
        print("\n---- \(command.title) ----")
        let result = session.exchange(frame: command.frame, mode: options.reportMode, timeout: options.timeout)
        print("发送(\(result.wireBytes.count)B, reportID=0, mode=\(options.reportMode.rawValue)): \(Hex.string(result.wireBytes))")
        print("写返回: \(HIDEnumeratorError.returnText(result.writeReturn))")
        for (index, response) in result.responses.enumerated() {
            print("读#\(index + 1) (n=\(response.count)): \(Hex.string(response))")
        }
        if let ackIndex = result.ackIndex, let offset = result.ackOffset {
            anyAck = true
            print("ACK: 是 (读#\(ackIndex + 1), report-ID offset=\(offset), resp[\(offset + 1)]==0)")
        } else {
            print("ACK: 否（写\(result.wrote ? "成功" : "失败")，未收到 resp[1]==0 的响应）")
        }
        decode(command: command, response: result.ackResponse ?? result.responses.last, ackOffset: result.ackOffset)
    }

    if options.repeatCount > 1 {
        print("\n---- 稳定性: 0x10 × \(options.repeatCount) ----")
        var acks = 0
        for n in 1...options.repeatCount {
            let result = session.exchange(frame: ReadCommand.deviceInfo.frame, mode: options.reportMode, timeout: options.timeout)
            if result.acked { acks += 1 }
            let status = result.acked ? "ACK" : "no-ack"
            print("  #\(n): \(status)  write=\(HIDEnumeratorError.returnText(result.writeReturn))")
            Thread.sleep(forTimeInterval: 0.05)
        }
        print("成功率: \(acks)/\(options.repeatCount)")
    }

    if anyAck {
        print("\n结果: 收到至少一个 ACK。请把完整输出保存到 docs/STATUS.md 的验证记录。")
        return 0
    }
    print("\n结果: 写操作已发出，但没有 ACK。这不等同于成功。")
    print("下一步：尝试 --report-id keep；若仍无响应，检查接口选择与鼠标是否休眠。")
    return 3
}

func runMonitor(options: Options) -> Int32 {
    let monitor: HIDMonitor
    do {
        monitor = try HIDMonitor()
    } catch {
        print("错误: \(error)")
        return 4
    }
    monitor.start()
    print("监听 HID 设备（\(Int(options.seconds)) 秒）。插拔鼠标观察 +/- 事件。\n")
    monitor.printSnapshot()
    let deadline = Date().addingTimeInterval(options.seconds)
    while Date() < deadline {
        let slice = min(0.5, deadline.timeIntervalSinceNow)
        if slice <= 0 { break }
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, slice, true)
    }
    monitor.stop()
    print("\n监听结束。")
    return 0
}

let options = parseOptions()
#if arch(arm64)
let architecture = "arm64"
#else
let architecture = "x86_64"
#endif
print("=== InphicMouse macOS HID Probe ===")
print("\(ProcessInfo.processInfo.operatingSystemVersionString)  arch=\(architecture)  IOKit HID\n")

let code: Int32
switch options.command {
case "list":
    code = runProbe(options: options)
case "probe":
    code = runProbe(options: options)
case "monitor":
    code = runMonitor(options: options)
default:
    usage()
    code = 4
}
exit(code)
