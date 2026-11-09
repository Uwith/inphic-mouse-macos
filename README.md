# InphicMouse for macOS

[![CI](https://github.com/Uwith/inphic-mouse-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/Uwith/inphic-mouse-macos/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

在 Apple Silicon Mac 上直接通过 USB HID 配置 **英菲克 Inphic IN9 升级版** 三模鼠标：读取设备信息、备份配置、改写按键映射、生成宏帧，不依赖 Windows 原厂软件。

> **状态：早期 / 实验性。** 只读探测与按键映射写入已在真实 2.4G 接收器（`VID_249A&PID_5C2F`）上验证；宏内容写入（`0x08`）已实现但**尚未在硬件上执行**。所有结论以 [docs/STATUS.md](docs/STATUS.md) 的帧日志为准。

## 为什么做这个项目

原厂配置软件只支持 Windows。本项目直接与鼠标的厂商 HID 配置接口（interface 2）通信，协议知识来自公开逆向项目 [RuiShu1024/InphicMouse](https://github.com/RuiShu1024/InphicMouse)，Swift 代码为本仓库独立实现。目标是把「读配置 / 备份 / 改键 / 写宏」变成可审计、可回滚的命令行工具，并为后续 SwiftUI App 打底。

## 功能状态

| 能力 | 状态 | 说明 |
|------|------|------|
| 枚举与识别设备 | ✅ 已验证 | VID `248A`/`249A`，配置接口 `bInterfaceNumber=2` |
| 只读配置 | ✅ 已验证 | `0x10`–`0x17`、`0x20` 全部 ACK |
| 配置备份 | ✅ 已验证 | 输出 JSON（原始帧），默认写入 `backups/`（gitignore） |
| 按键映射写入 `0x09` | ✅ 已验证 | ACK + `0x11` 读回一致 + HID 报告路径实测 |
| 宏编码 / 分帧 / 校验 | ✅ 单元自检 | 194 项自检，含上游 Golden 字节 |
| 宏内容写入 `0x08` | ⚠️ 未执行 | 工具已实现；宏不可读回，覆盖不可恢复 |
| DPI / 灯光 / 休眠 | 🔬 仅只读 | Codec 已实现，CLI 尚未提供写入 |
| SwiftUI 正式 App | ⏳ 未开始 | Phase 4，依赖前 3 阶段稳定 |

## 环境要求

- Apple Silicon Mac（arm64），macOS 14+
- Swift 6 工具链。只构建命令行工具时 Command Line Tools 足够；构建 `.app` 需要完整 Xcode
- USB 有线或 2.4G 接收器连接。**蓝牙模式未验证**，厂商配置接口通常只在 USB/2.4G 下出现
- 关闭可能占用 HID 接口的原厂软件或其它鼠标工具

## 5 分钟快速开始

```bash
git clone https://github.com/Uwith/inphic-mouse-macos.git
cd inphic-mouse-macos

# 1) 纯协议自检（不需要硬件）
swift run protocol-selftest          # 194 passed, 0 failed

# 2) 枚举并只读探测真实设备
cd tools/hid-probe
swift build
.build/debug/hid-probe list
.build/debug/hid-probe probe         # 自动选 INPHIC 接口 2，读 0x10/0x12/0x13/0x15
```

`probe` 只发送白名单内的只读命令，拒绝写入、复位与未知命令。

## 写入按键映射

先备份，再写。`set-key` 默认是 dry-run，只有显式 `--yes` 才发送。

```bash
cd tools/macro-tool
swift build

.build/debug/macro-tool backup
# 例：后侧键 = 下一空间（Ctrl+→），前侧键 = 上一空间（Ctrl+←）
.build/debug/macro-tool set-key --set 3=70014F --set 4=700150 --yes
```

`K=HHHHHH` 是「键下标 = 3 字节十六进制条目」：

- `70 01 4F`：`0x70` 键盘键，修饰掩码 `0x01`（左 Ctrl），HID Usage `0x4F`（→）
- `70 01 50`：左 Ctrl + ←
- `70 08 2F` / `70 08 30`：Cmd + `[` / `]`（浏览器后退/前进）

写入后工具会读回 `0x11` 并逐项比对。恢复：

```bash
.build/debug/macro-tool restore --backup backups/<file>.json --yes
```

> 改键前请确认 macOS 的「调度中心 → 左/右移动一个空间」快捷键已启用（默认 Control + ←/→）。工具只发送组合键，不修改系统设置。

## 宏（实验）

```bash
.build/debug/macro-tool plan  --key 5   # 只读：打印 0x08 宏帧与 0x09 映射
.build/debug/macro-tool apply --key 5 --yes
```

`apply` 会先备份，再写 `0x08`（`A↓ 100ms A↑`）和 `0x09`，最后读回按键映射。

**注意：**

- 宏内容**无法从设备读回**（`0x18` 无响应），覆盖后不能恢复旧宏。
- `apply` 尚未在真实设备上执行；不要把「写成功 / ACK / 读回一致」当成「宏已执行」。
- 绑定到某键会覆盖该键原功能；第 6 键是 DPI 键。
- 宏槽 = 键下标（官方约定），第 6 键对应槽 5。

## 文档

| 文档 | 内容 |
|------|------|
| [docs/USAGE.md](docs/USAGE.md) | 中文使用手册：安装、备份、改键、恢复、排错 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 模块划分、数据流、设计决策 |
| [docs/REVERSE_ENGINEERING.md](docs/REVERSE_ENGINEERING.md) | 协议审计、帧格式、按键/宏编码、证据边界 |
| [docs/PORTING_PLAN.md](docs/PORTING_PLAN.md) | Windows → macOS 移植计划与阶段验收 |
| [docs/STATUS.md](docs/STATUS.md) | 实际执行过的验证、原始帧、未验证清单 |
| [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) | 项目原始任务书 |
| [References/UPSTREAM.md](References/UPSTREAM.md) | 上游仓库与审计提交 |

## 工作原理（简版）

```text
IOHIDManager (VID 248A/249A)
        │
        ├── interface 0: 鼠标（5 个 HID 按钮 + 滚轮轴）
        ├── interface 1: 键盘（6KRO + Consumer）
        └── interface 2: 厂商配置（32 字节 in/out）
                 │
                 ├── 0x10–0x17 / 0x20  只读配置
                 ├── 0x08              宏内容
                 └── 0x09              按键映射（每键 3 字节）
```

- 写帧逻辑长度 33 字节，首字节是 report ID `0`；macOS 上必须 **strip** 成 32 字节发送，否则无响应。
- 校验和只覆盖 payload 区（`buf[5...31]`），不覆盖头部。
- 设备返回的 `0x11` 实际是 6 键映射（5 个 HID 按钮 + DPI 键），上游把它当握手。
- 验证状态分四层：`发送` / `ACK` / `读回` / `实际执行`；本项目不把前三层当作第四层。

## 构建与测试

```bash
swift build
swift run protocol-selftest                 # 194 项

cd tools/hid-probe
swift build && swift run probe-selftest     # 76 项

cd ../macro-tool
swift build
```

CI 在 macOS 上构建并运行两套自检，不接触真实硬件。

## 设备与兼容性

- 已验证：2.4G 接收器 `VID_249A&PID_5C2F`，Product `Wireless-Receiver`，接口 2，32/32 报告。
- 上游记录：`VID_248A&PID_8266`。PID 可能随接收器批次/模式变化；工具按 **厂商 VID + interface 2** 选择，不硬编码 PID。
- HID 描述符只声明 5 个按钮；DPI 键由固件处理，不在标准鼠标按钮中。
- 蓝牙模式、其它 IN9 批次、其它英菲克型号**未验证**。
- 当前按键写入要求 `0x11` 返回 6 个条目；5 键版本会被拒绝写入。

## 安全边界

- 不做固件升级、出厂复位或未知写命令。
- 写操作必须显式 `--yes`，并先备份可读配置。
- 备份与原始日志留在本机，不要提交到仓库（`backups/`、`logs/` 已 gitignore）。
- 硬件写入有风险；请自行确认设备型号与备份可用。

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。欢迎补充其它批次/型号的只读探测结果、macOS 版本兼容性与协议证据。

## 许可证与声明

本项目代码以 [MIT License](LICENSE) 发布。项目与英菲克（Inphic）无关联，不包含原厂软件代码；协议事实来自公开逆向资料，上游仓库没有 LICENSE 文件，本项目未复制其代码。
