# macOS 移植设计（Phase 0 产出）

目标：Swift 6 / SwiftUI / IOKit 原生实现；协议层与 UI 完全分离；所有硬件写入串行化并可审计。最低系统 **macOS 14.0**（`@Observable`、`NavigationSplitView`），仅 arm64。

## 1. 模块划分（Phase 2 起）

```
InphicMouse/
├── Package.swift                    SwiftPM 工作区
├── Sources/
│   ├── InphicMouseProtocol/         纯协议，无 IOKit / 无 UI
│   │   ├── MouseReport.swift        33 字节帧 + 校验和
│   │   ├── KeyCodes.swift           VK/HID ↔ 修饰位
│   │   ├── DpiConversion.swift      DPI ↔ 寄存器
│   │   ├── MacroMacroCodec.swift    0x08 编码 / 分帧
│   │   ├── KeyMapCodec.swift        0x09 条目与重定位
│   │   ├── DeviceInfoCodec.swift    0x10 解析
│   │   ├── SettingsCodecs.swift     0x02–0x07 / 0x0C–0x0E
│   │   └── Models/                  Macro、MacroEvent、KeyEntry、DeviceSnapshot
│   ├── InphicMouseHID/              IOKit 传输
│   │   ├── HIDEnumerator.swift      IOHIDManager 枚举 + bInterfaceNumber
│   │   ├── HIDDeviceSession.swift   打开 / 写 / 异步读 / 超时
│   │   ├── HIDTransport.swift       actor：串行化 + ACK + 日志
│   │   └── DeviceLocator.swift      VID/PID + 接口匹配
│   ├── InphicMouseServices/         业务层
│   │   ├── MouseService.swift       协议接口（连接、读回、上传宏）
│   │   ├── RealMouseService.swift   真机实现
│   │   └── SimulatedMouseService.swift 无设备预览（明确标记 simulated）
│   └── InphicMouseApp/              SwiftUI（Phase 4）
│       ├── App/
│       ├── Features/{Dashboard,MacroEditor,KeyMapping,DeviceSettings,Diagnostics}
│       └── Resources/
├── Tests/InphicMouseProtocolTests/  Golden Test（上游字节）
└── docs/
```

规则：

- `InphicMouseProtocol` **不得** import IOKit / AppKit / SwiftUI；可在任意平台编译和测试。
- View 不得直接调用 HID；只能调用 `MouseService`。
- `SimulatedMouseService` 返回值必须带 `isSimulated = true`，UI 必须显式标注，禁止冒充真机。

## 2. IOKit 传输设计

### 2.1 枚举与定位

1. `IOHIDManagerCreate` + `IOHIDManagerSetDeviceMatching(nil)` + `IOHIDManagerOpen(kIOHIDOptionsTypeNone)`。
2. `IOHIDManagerCopyDevices` 取全部 IOHIDDevice；读取 `VendorID`、`ProductID`、`PrimaryUsagePage`、`PrimaryUsage`、`Product`、`Transport`、`LocationID`、`MaxInputReportSize`、`MaxOutputReportSize`。
3. 通过 `IOHIDDeviceGetService` + `IORegistryEntrySearchCFProperty(..., "bInterfaceNumber", ..., kIORegistryIterateRecursively | kIORegistryIterateParents)` 获取 USB 接口号，作为 Windows `mi_02` 的等价条件。
4. 候选：`VID ∈ {0x248A, 0x249A}`（**不强制 PID**），优先 `bInterfaceNumber == 2`；若不存在则列出所有候选并拒绝自动打开，要求用户显式选择（`--index`）。
   实测 2.4G 接收器为 `PID 0x5C2F`（上游记录 `0x8266`），因此 PID 只能作为提示，不能作为唯一匹配条件。日志必须记录实际 PID/序列号。
5. 不使用 `kIOHIDOptionsTypeSeizeDevice`；不打开系统鼠标的 Generic Desktop collection 做输入监听。

### 2.2 打开与写入

- `IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone)`；失败时原样打印 `IOReturn`（`kIOReturnExclusiveAccess`、`kIOReturnNotPermitted` 等）。
- 写：`IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, bytes, count)`。
- **report ID 语义（Phase 1 已实测，2026-11-09）**：协议帧 33 字节且首字节为 0。实测设备只接受：
  - `strip`（默认）：传 `bytes[1...]` 共 32 字节，`reportID = 0` → 正常 ACK；
  - `keep`：完整 33 字节 → 写成功但无任何响应。
  因此正式实现固定使用 `strip`；Probe 保留 `--report-id keep` 仅用于复现实验。
- 写成功后进入 ACK 等待；**绝不**把 `IOReturnSuccess` 当成 ACK。

### 2.3 读取与 ACK

- `IOHIDDeviceRegisterInputReportCallback` 注册固定缓冲区；设备用 `IOHIDDeviceScheduleWithRunLoop` 挂到专用线程的 runloop。
- 每次交换：写 → 在超时窗口内泵 runloop（例如 5 ms 步进，总超时 300–1000 ms）→ 收集输入报告。
- 响应可能是 30–33 字节；同时尝试两种偏移（是否含 report ID），ACK 条件为剥掉 ID 后 `resp[1] == 0`。
- 超时、设备移除（`kIOReturnNotAttached` / 写失败）→ 取消未完成请求并清空会话，不无限重试。
- 重试上限：默认 12 次读轮询（与上游一致），每次 100 ms 量级；总时长有硬上限。

### 2.4 并发

- `actor HIDTransport` 串行化所有写/读；`MouseService` 的每个操作 `await transport.exchange(frame)`。
- IOKit runloop 线程与 actor 通过 `AsyncStream<Data>` / `CheckedContinuation` 桥接；不跨线程共享 `IOHIDDevice`。
- 插拔：`IOHIDManagerRegisterDeviceMatchingCallback` / `RemovalCallback`，转发为 `AsyncStream<DeviceEvent>`；移除时让所有等待中的 continuation 以 `HIDError.deviceRemoved` 结束。

## 3. 协议层移植清单（Phase 2）

| 上游 | Swift | Golden 来源 |
|------|-------|-------------|
| `MouseReport.cs` | `MouseReport` | `MouseReportTests`（校验和 18、0x100 回绕、头部不参与） |
| `KeyCodes.cs` | `KeyCodes` | `KeyMapTests` 的 VK/修饰位表 |
| `DpiConversion.cs` | `DpiConversion` | `DpiConversionTests` 全表 + ic 0x11 实机寄存器 |
| `DpiCodec.cs` | `DpiCodec` | `CodecTests.DpiCodecTests` |
| `LightCodec.cs` | `LightCodec` | `CodecTests.LightCodecTests` |
| `DeviceSettingsCodec.cs` | `DeviceSettingsCodec` | 颜色/传感器/休眠/回报率 4 例 |
| `DeviceInfoCodec.cs` | `DeviceInfoCodec` | 0x0102 固件、ic 0x25、电量 77 |
| `MacroCodec.cs` | `MacroCodec` | 官方抓包 2 例 + 10 记录折叠 + 修饰键 |
| `KeyMapCodec.cs` | `KeyMapCodec` | 默认载荷、5/6 键、宏重定位 `0x90 0x26 0x01` |

测试要求：

- 逐字节数组相等；同时断言长度、校验和、边界（空载荷、27 字节满载荷、28 字节拒绝）。
- 错误路径：非法档数（0/7）、非法键数（0/10）、模式 2 缺 7 色。
- 本机只有 CLT、没有 XCTest；Phase 1 使用 `swift run probe-selftest` 可执行自检（76 项）。Phase 2 若安装 Xcode，再迁移到 Swift Testing / XCTest。
- 不在协议测试里访问硬件。

## 4. 服务层语义（必须四态）

```swift
struct SendOutcome {
    var write: WriteState        // .failed(IOReturn) / .sent
    var ack: AckState            // .none / .received(Data)
    var readback: ReadbackState  // .notRequested / .matched / .mismatched / .unsupported
    var execution: ExecutionState// .unknown / .observedByUser
}
```

- `写入鼠标` 只返回 `write/ack`；`读回验证` 单独一步；`实际执行` 必须由用户按键观察后手动确认，程序不伪造。
- 宏上传：先 `0x08`（可多帧，逐帧等待 ACK），再 `0x09` 绑定；任一步失败即停止并保留日志。
- 设备断开：所有进行中的请求以明确错误终止；UI 显示原因。
- 原始帧日志：带时间戳、方向、命令、十六进制、ACK 状态；可导出 `.log`。日志默认不落盘，导出时用户选择路径。

## 5. 权限与环境

| 能力 | 权限 | 说明 |
|------|------|------|
| 枚举 / 打开厂商 HID 接口 / SetReport | 通常无需 TCC | 需 Phase 1 实测；若被拒，记录 `IOReturn` |
| 读取键盘/鼠标输入做宏录制 | 输入监控（Input Monitoring）+ 辅助功能（Accessibility） | Phase 4 才需要；必须给系统设置引导，不能静默失败 |
| 分发 | 无证书 → 未签名包 | 文档说明 Gatekeeper 右键打开 / `xattr`，不声称已公证 |

本机现状：仅有 Command Line Tools（`/Library/Developer/CommandLineTools`），没有完整 Xcode。Phase 1/2 使用 SwiftPM 构建；Phase 4 的 `.app` 需要安装 Xcode 后用 `xcodebuild` 或手写 `.app` bundle 打包。

## 6. 开发阶段与验收

| 阶段 | 交付 | 验收（必须真实执行） |
|------|------|----------------------|
| Phase 1 | `tools/hid-probe` | **已完成（只读）**：枚举、接口定位、打开、0x10–0x17/0x20 全部 ACK、5/5 稳定性。见 `docs/STATUS.md`。 |
| Phase 2 | Swift 协议层 + Golden Test | 自检全绿（当前 CLT 环境 `swift run`；装 Xcode 后用 `swift test`）；与上游 C# 相同输入产生相同字节。 |
| Phase 3 | 宏上传工具 | 写 A↓100ms A↑ 到指定槽 → ACK → 绑定按键 → 用户按键确认执行；拔插后仍有效。读回不支持则记录。 |
| Phase 4 | SwiftUI App | 只调用已验证的 Service；设备主页/宏编辑器/按键映射/设置/诊断。 |
| Phase 5 | `.app` / `.dmg` / 文档 | arm64 构建、未签名说明、用户指南、兼容性表。 |

Phase 1 未通过前**不开始** Phase 4。

## 7. 真机验证清单（交给用户执行）

1. 有线连接 IN9 升级版，运行 `hid-probe list`，确认出现 `VID 248A / PID 8266` 的多个接口，记录各接口的 `bInterfaceNumber`、Usage Page、输入/输出报告长度。
2. 运行 `hid-probe probe`，确认自动选中接口 2；若选错，用 `--index` 指定。
3. 分别用 `--report-id strip` 与 `keep` 各跑一次，记录哪种能收到 `0x10` 响应。
4. 保存完整十六进制日志，核对固件版本、`ic_type`、电量、在线标志是否合理。
5. 插拔鼠标，运行 `monitor`，确认出现/消失事件。
6. 2.4G 接收器重复步骤 1–5（VID 249A）。
7. 若全部无响应：记录 `IOReturn`、系统版本、是否授予输入监控，停止后续写入。

## 8. 风险与待决

| 风险 | 影响 | 缓解 |
|------|------|------|
| report ID / 缓冲区语义不符 | 设备无响应 | Probe 双模式 + 原始日志；不改协议帧 |
| 配置接口不是 `bInterfaceNumber == 2` | 打开错误接口 | 列出全部候选 + 人工选择；不盲目写 |
| macOS 对鼠标 HID collection 独占 | 打开失败 | 只打开厂商接口；不 seize；报告 IOReturn |
| 上游无 LICENSE | 无法合法分发衍生代码 | 只复用协议事实；联系作者确认授权 |
| 宏读回不存在 | 无法自动验证宏内容 | 明确标记「不支持读回」；用按键执行验证 |
| 单只鼠标验证 | 不能推广到其它型号/固件 | README/UI 标注兼容范围；写入前备份提示 |
| 无完整 Xcode | 无法直接出 .app | Phase 1/2 用 SwiftPM；Phase 4 前安装 Xcode |
