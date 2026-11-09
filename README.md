# InphicMouse for macOS

在 Apple Silicon Mac 上直接通过 USB HID 配置 **英菲克 Inphic IN9 升级版** 三模鼠标（板载宏、按键映射、DPI、灯光等），不依赖 Windows 原厂软件。

- 目标机：Mac mini M4 / Apple Silicon / macOS 14+
- 语言：Swift 6，UI：SwiftUI，HID：IOKit（IOHIDManager / IOHIDDevice）
- 协议依据：[RuiShu1024/InphicMouse](https://github.com/RuiShu1024/InphicMouse)（C# / WinUI 3），审计见 [docs/REVERSE_ENGINEERING.md](docs/REVERSE_ENGINEERING.md)
- 原始任务书：[docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)

## 当前状态

| 阶段 | 内容 | 状态 |
|------|------|------|
| Phase 0 | 上游审计、协议分析、macOS 可行性、架构设计 | 完成（无硬件） |
| Phase 1 | macOS HID Probe：枚举 / 识别 / 安全读取 | **通过（只读，2026-11-09）**，见 [docs/STATUS.md](docs/STATUS.md) |
| Phase 2 | Swift 协议层 + Golden Test | **完成**（194 项自检，2026-11-09） |
| Phase 3 | 宏上传真机验证 | **工具完成，写入未执行**（等待用户确认；见 docs/STATUS.md） |
| Phase 4 | SwiftUI 正式界面 | 未开始（Phase 1–3 通过后才开始） |
| Phase 5 | 打包 / 测试 / 文档 | 未开始 |

> Phase 1 已在真实 2.4G 接收器（`VID_249A&PID_5C2F`，接口 2）上完成只读验证：0x10–0x17、0x20 全部 ACK，report ID 必须使用 `strip`（32 字节）。该 PID 与上游记录的 `0x8266` 不同，写入类命令仍未验证。

## 构建与运行 Probe

协议层（仓库根目录）：

```bash
swift build
swift run protocol-selftest     # 194 项：帧/校验和/各 Codec/宏分块/KeyMap/DPI 换算
```

Probe（Phase 1 工具）：

```bash
cd tools/hid-probe
swift build -c release
.build/release/hid-probe list          # 枚举全部 HID 接口
.build/release/hid-probe probe         # 自动识别 VID 248A/249A 接口 2 并读 0x10/0x12/0x13/0x15
.build/release/hid-probe probe --index 2
.build/release/hid-probe monitor --seconds 30
swift run probe-selftest               # 76 项协议帧自检（CLT 环境无 XCTest）
```

宏工具（Phase 3；`apply`/`restore` 默认拒绝，必须 `--yes`）：

```bash
cd tools/macro-tool
swift build
.build/debug/macro-tool backup                 # 备份 0x10–0x17/0x20 到 backups/
.build/debug/macro-tool plan --key 5           # 只读 dry-run：打印 0x08/0x09 帧
.build/debug/macro-tool apply --key 5 --yes    # 真实写入（会先备份）
.build/debug/macro-tool set-key --set 3=70014F --set 4=700150 --yes
                                               # 侧键：后=Ctrl+→（下一空间），前=Ctrl+←（上一空间）
.build/debug/macro-tool restore --backup backups/<file>.json --yes
```

Probe 只发送协议文档中已确认的**只读**命令（0x10–0x17、0x20），拒绝任何写入、复位或未知命令。原始帧以十六进制打印，可重定向保存：

```bash
.build/release/hid-probe probe 2>&1 | tee ~/inphic-probe.log
```

## 目录

```
docs/           审计、移植计划、状态、原始需求
Sources/        InphicMouseProtocol（纯协议层）+ ProtocolSelfTest
tools/hid-probe Phase 1 独立 HID 探针（SwiftPM 可执行程序，依赖协议层）
References/     上游仓库本地副本（gitignore，见 docs/REVERSE_ENGINEERING.md）
```

后续的 App、Protocol、HID 模块将在 Phase 1 真机通过后按 `docs/PORTING_PLAN.md` 建立。

## 已知前置风险

- 上游仓库**没有 LICENSE 文件**（默认保留所有权利）。本仓库只复用协议事实（帧布局、换算、抓包字节），Swift 代码独立实现；正式分发前需确认授权。
- macOS 上的 report ID 处理、复合设备接口 2 的定位方式与 Windows 不同，属于 Phase 1 必须实测的内容。
- 未签名 App 会触发 Gatekeeper；文档不会声称已完成公证。

## 安全边界

- 不发送未验证的写命令、不做固件升级、不做出厂复位。
- 区分「写成功 / 收到 ACK / 读回成功 / 宏实际执行」，不把前两者当作成功。
- 所有原始帧日志保留在本机，不上传。
