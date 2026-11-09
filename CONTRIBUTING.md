# 贡献指南

感谢参与。这个项目的核心不是 UI，而是**可复现的硬件协议证据**。提交代码前请先读 [docs/REVERSE_ENGINEERING.md](docs/REVERSE_ENGINEERING.md) 与 [docs/STATUS.md](docs/STATUS.md)。

## 环境

- Apple Silicon Mac，macOS 14+
- Swift 6（CLT 或 Xcode）
- 可选：IN9 升级版鼠标 + USB/2.4G 接收器（硬件相关改动必需）

```bash
git clone https://github.com/Uwith/inphic-mouse-macos.git
cd inphic-mouse-macos
swift build
swift run protocol-selftest
```

## 测试

| 命令 | 范围 |
|------|------|
| `swift run protocol-selftest` | 协议层 194 项，无硬件 |
| `cd tools/hid-probe && swift run probe-selftest` | 探针 76 项，无硬件 |
| `cd tools/hid-probe && .build/debug/hid-probe probe` | 真机只读 |
| `cd tools/macro-tool && .build/debug/macro-tool backup` | 真机只读备份 |

提交前至少跑两套自检。涉及硬件的改动，请在 PR 中附上：

- macOS 版本、Mac 型号
- `hid-probe list` 中目标接口行
- 发送/响应原始十六进制
- 四态结果：`发送` / `ACK` / `读回` / `实际执行`
- 明确哪些是实测、哪些是推断

## 硬件测试规则

1. **先只读，后写入。** 新设备先跑 `hid-probe probe`，确认所有只读命令。
2. **写前备份。** 使用 `macro-tool backup`；不要把备份提交到仓库。
3. **不猜测命令。** 没有上游代码、抓包或文档证据的写入命令不要加。
4. **不把 ACK 当执行。** 宏是否真的触发、按键是否真的切换空间，必须人工观察。
5. **不做固件升级/复位**，除非有完整证据和恢复路径。
6. 测试写入时一次只改一个变量；记录写入前后的 `0x11`。

## 代码风格

- Swift 6，遵循现有文件结构；协议逻辑放 `Sources/InphicMouseProtocol`，IOKit 会话放 `HIDProbeCore`。
- 新增协议逻辑必须配自检；不要只加 CLI 输出。
- 避免强制解包和静默失败；错误要带上下文。
- 帧日志用 `Hex.string`，不要手工拼接格式。
- 不引入第三方依赖，除非有明确必要。
- 文档使用中文；代码标识符、命令、协议字段保持原样。

## 协议改动的流程

1. 在 `docs/REVERSE_ENGINEERING.md` 补证据（上游代码/抓包/实机响应）。
2. 修改 Codec；保持字节级兼容。
3. 在 `Sources/ProtocolSelfTest/main.swift` 加 Golden/边界测试。
4. 在 `docs/STATUS.md` 记录实测环境与结果；未验证就写“未验证”。
5. 更新 `docs/ARCHITECTURE.md` 或 `docs/USAGE.md`（如影响使用方式）。

## 提交与 PR

- 一个提交只做一件事；消息用祈使句，例如 `Add DPI write command`。
- PR 描述包含：动机、改动、验证命令与结果、风险/回滚。
- 不要提交：`backups/`、`logs/`、`References/InphicMouse/`、`.build/`、设备序列号、个人路径。
- 新文件如包含设备唯一标识，请脱敏。

## 报告问题

请附：

```bash
sw_vers
uname -m
hid-probe list
```

以及失败命令的完整输出（可脱敏序列号）。如果是写入问题，附上对应备份文件名和 `0x11` 读回结果。

## 许可证

贡献即表示同意以 [MIT License](LICENSE) 发布。
