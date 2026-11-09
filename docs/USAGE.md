# 使用手册

本文面向最终用户，说明如何在 macOS 上构建、只读验证、备份、改键与恢复。协议细节见 [REVERSE_ENGINEERING.md](REVERSE_ENGINEERING.md)，验证状态见 [STATUS.md](STATUS.md)。

## 1. 适用范围

| 项 | 要求 |
|----|------|
| 电脑 | Apple Silicon Mac（arm64），macOS 14+ |
| 鼠标 | 英菲克 Inphic IN9 升级版 |
| 连接 | USB 有线或 2.4G 接收器；**蓝牙未验证** |
| 工具链 | Swift 6；只跑 CLI 用 Command Line Tools 即可 |

已验证设备：`VID_249A&PID_5C2F`，Product `Wireless-Receiver`，`bInterfaceNumber=2`，输入/输出报告 32/32。

> 写入前请关闭原厂 Windows 软件、虚拟机直通工具或其它可能占用 HID 接口的程序。正常使用鼠标时无需关闭。

## 2. 构建

```bash
git clone https://github.com/Uwith/inphic-mouse-macos.git
cd inphic-mouse-macos

swift build
swift run protocol-selftest          # 194 passed, 0 failed

cd tools/hid-probe && swift build
cd ../macro-tool && swift build
```

目录说明：

```text
Sources/InphicMouseProtocol/   纯协议层（帧、Codec、宏、按键映射）
tools/hid-probe/               只读探针 + 设备枚举
tools/macro-tool/              备份 / 改键 / 宏上传 / 恢复
docs/                          审计、架构、状态、原始需求
```

## 3. 第一次只读验证

```bash
cd tools/hid-probe
.build/debug/hid-probe list
```

输出中应出现类似：

```text
[ 2] VID_249A&PID_5C2F  if=2  UP=0x0001 U=0x0000  in=32 out=32 feat=0  "Wireless-Receiver"  USB
```

`if=2` 是厂商配置接口（Windows 的 `mi_02`）。然后：

```bash
.build/debug/hid-probe probe
```

预期 `0x10`–`0x17`、`0x20` 全部 `ack=true`。如果读到 `0x11`，它就是当前 6 键映射：

```text
[0] 左键
[1] 右键
[2] 中键 / 滚轮按下
[3] 侧键（后）
[4] 侧键（前）
[5] DPI 键
```

## 4. 备份配置

每次写入前都先备份。工具也会在 `set-key --yes` 时自动备份。

```bash
cd tools/macro-tool
.build/debug/macro-tool backup
# 输出到 backups/inphic-YYYYMMDD-HHmmss.json
```

备份包含 `0x10`–`0x17`、`0x20` 的原始响应和 `0x11` 按键映射。`backups/` 已在 `.gitignore` 中，不要提交到公开仓库。

**备份不能恢复宏内容。** 宏只能写、不能读；覆盖某个槽的旧宏后无法找回。

## 5. 改键

### 5.1 改键命令

```bash
.build/debug/macro-tool set-key --set 3=70014F --set 4=700150 --yes
```

- `--set K=HHHHHH`：把键下标 `K` 改为 3 字节条目 `HHHHHH`
- 不带 `--yes` 时只打印 dry-run，不写入
- 写入后自动读回 `0x11` 并逐项比对
- 可一次写多个键，例如同时改 3 和 4

### 5.2 条目编码

每个键 3 字节：`[功能类型, v1, v2]`。

| 功能 | 条目 | 说明 |
|------|------|------|
| 左键 | `10 01 00` | 鼠标按钮位 |
| 右键 | `10 02 00` | |
| 中键 | `10 04 00` | 滚轮按下 |
| 侧键后 | `10 08 00` | HID Button 4 |
| 侧键前 | `10 10 00` | HID Button 5 |
| DPI 循环 | `40 01 00` | |
| DPI + / − | `40 02 00` / `40 03 00` | 上游标注未实测 |
| 左 Ctrl + ← | `70 01 50` | 修饰掩码 `01`，HID Left `50` |
| 左 Ctrl + → | `70 01 4F` | HID Right `4F` |
| Cmd + `[` | `70 08 2F` | 浏览器后退 |
| Cmd + `]` | `70 08 30` | 浏览器前进 |
| 宏（槽 5，单次） | `90 26 01` | 低半字节 = 键下标 + 1 |

修饰键掩码（`v1`）：LCtrl `0x01`、LShift `0x02`、LAlt `0x04`、LGui `0x08`、RCtrl `0x10`、RShift `0x20`、RAlt `0x40`、RGui `0x80`。

### 5.3 切换桌面/空间

先确认系统快捷键：

1. 打开「系统设置 → 键盘 → 键盘快捷键 → 调度中心」
2. 勾选「左移一个空间」和「右移一个空间」
3. 默认是 `Control + ←` / `Control + →`

然后写入：

```bash
# 后侧键 = 下一空间，前侧键 = 上一空间
.build/debug/macro-tool set-key --set 3=70014F --set 4=700150 --yes
```

写入后按两个侧键测试。若方向相反，把两个条目对调：

```bash
.build/debug/macro-tool set-key --set 3=700150 --set 4=70014F --yes
```

> 鼠标发送的是标准 HID 键盘报告；如果系统快捷键被改过，或焦点在一个拦截该组合键的应用里，空间可能不切换。

## 6. 恢复

```bash
.build/debug/macro-tool restore --backup backups/inphic-YYYYMMDD-HHmmss.json --yes
```

`restore` 只恢复备份里的 `0x11` 按键映射，不会恢复宏内容。恢复后同样会发送 `0x09`，建议再读一次确认：

```bash
.build/debug/macro-tool set-key --set 3=70014F --set 4=700150
# 不带 --yes，会打印当前映射供核对
```

## 7. 宏（实验性）

```bash
# 只读：打印将发送的 0x08 帧和 0x09 映射
.build/debug/macro-tool plan --key 5

# 真实写入（会先备份）；尚未在硬件上验证
.build/debug/macro-tool apply --key 5 --yes
```

测试宏内容固定为：按下 `A` → 延时 100ms → 松开 `A`，循环 1 次。

注意：

- `--key 5` 是第 6 个键（DPI 键），写入后会覆盖 DPI 功能。
- 宏槽 = 键下标；第 6 键对应槽 5。
- `0x08` 写成功、收到 ACK、`0x09` 读回一致，都**不代表**宏已被鼠标执行。必须实际按键观察。
- 宏内容不可读回，旧宏不可恢复。

## 8. 排错

| 现象 | 处理 |
|------|------|
| `IOHIDManagerOpen 失败: kIOReturnUnsupported` | 系统里还有其它 HID 设备（例如另一把 2.4G 键盘）导致“打开全部”失败；本工具会自动退回只匹配 Inphic 厂商。仍失败时拔掉其它 HID 设备再试。 |
| `kIOReturnNotPermitted` | 首次运行可能瞬时出现；重试一次。仍失败时检查是否被安全软件拦截。 |
| 找不到接口 2 | 确认鼠标处于 USB/2.4G 模式；蓝牙模式通常没有厂商接口。`hid-probe list` 查看全部接口。 |
| `0x11 未返回可解析的按键映射` | 设备刚唤醒或会话竞争；工具已重试 3 次。可加大超时：`--timeout-ms 3000`。 |
| 写入返回 `write=false` | 接口未打开或被占用；关闭原厂软件/虚拟机直通后重试。 |
| 写入成功但无 ACK | 不要反复盲写；先读回 `0x11` 看映射是否变化，再决定是否恢复。 |
| 侧键方向相反 | 交换两个键的条目（见 5.3）。 |
| 侧键有键盘报告但空间不切换 | 检查系统快捷键是否启用；用文本编辑器确认按键是否被应用拦截。 |
| 改完想还原 | `restore --backup <对应备份>.json --yes`。 |

## 9. 安全与免责声明

- 本项目不提供固件升级、复位或未验证的写命令。
- 写入会修改鼠标板载配置；请先备份并确认设备型号。
- 本项目与英菲克无关联；按 MIT License「按原样」提供，不承担硬件损坏或数据丢失责任。
