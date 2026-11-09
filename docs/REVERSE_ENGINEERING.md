# Phase 0 — 上游逆向审计

审计对象：`https://github.com/RuiShu1024/InphicMouse`
审计提交：`3f2ce39c57cbb206062e0fd27118717a83670bb9`（2026-10-09，`Update README.md`）
审计日期：2026-11-09

本文件只记录**上游已经给出证据的协议事实**，以及移植到 macOS 时必须重新验证的点。凡上游自己标注「待实机确认」的内容，这里同样标为未知，不做推断。

---

## 1. 仓库与法律状态

| 项 | 结果 |
|----|------|
| 语言 / UI | C# / .NET 9 / WinUI 3 |
| 许可证 | **仓库内没有 LICENSE 文件**。按著作权默认规则为「保留所有权利」，不能直接复制代码再分发。 |
| 实测硬件 | 仅一只 IN9 升级版：USB `VID_248A`、2.4G `VID_249A`、`PID_8266`、`ic_type 0x11`、型号元数据 `3311` |
| 协议文档 | `docs/hid-protocol.md`（159 行），来源为 Ghidra 反编译原厂 `Inphic Mouse.exe`（含 PDB 符号） |
| 校准方法 | Wireshark + USBPcap 抓原厂软件报文，逐字节对照 |
| 测试 | `tests/InphicMouse.Protocol.Tests`：README 称 91 项全绿；NEXT-STEPS 称 88 项。未在上游运行（本机无 .NET 工具链），仅作为 Golden 数据来源。 |

**移植策略**：不复制 C# 源码；Swift 侧按本文件记录的字节布局与上游测试中的 Golden 字节独立实现。协议事实本身不受著作权保护，但正式分发前仍建议取得上游作者授权或在 README 致谢并说明来源。

## 2. 传送层（上游证据 + macOS 差异）

上游（`src/InphicMouse.Hid/`、`Comm/MouseCommLink.cs`）：

- 底层 hidapi，使用 **Output Report / Input Report**（非 Feature）。
- 发送固定 **33 字节**（`hid_write(dev, buf, 33)`），`buf[0]` 为 report ID，恒 `0`。
- 读取 `hid_read_timeout(buf, 30~0x41, timeout)`；Windows 原始 `ReadFile` 首字节为 report ID，上游统一剥掉后再解析。
- ACK 判定：收到响应且 `resp[1] == 0`（剥掉 report ID 后）。`DriverComm::SetDeviceData` 最多重试 50 次，上游为 UI 响应改成 12 次。
- 写成功 ≠ ACK ≠ 执行成功。上游 `SendResult` 明确区分 `WriteOk` / `AckOk` / `Response`，但部分 `Apply*` 只用 `WriteOk` 判定。

macOS 差异（Phase 1 必测）：

1. `IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, bytes, len)` 的 `reportID` 与 buffer 是否包含 ID 的语义，与 hidapi 不同。Probe 提供 `--report-id strip|keep` 两种模式并打印实际下发字节。
2. 响应通过 `IOHIDDeviceRegisterInputReportCallback` 异步到达；需要 runloop 泵 + 超时，不能像 Windows 那样阻塞读。
3. 复合设备在 Windows 用接口路径 `mi_02` 定位；macOS 的 IOHIDDevice 没有 `mi_02` 路径。Probe 通过 IORegistry 读取父节点 `bInterfaceNumber` 作为等价条件，并打印全部候选供人工确认。

## 3. 帧格式（已确认）

```
偏移   0      | 1      | 2   3   4          | 5 ................ 31      | 32
      报告ID  | 命令码 | 00  01  载荷长度    | 载荷（27 字节，参与校验）   | 校验和
```

- 固定长度 33（`0x21`）。
- `checksum = sum(buf[5...31]) & 0xFF`；头部 `buf[1...4]` 不参与。
- 载荷最大 27 字节。
- 命令码与读回命令相差 `0x10`（写 `0x0X` → 读 `0x1X`），`0x20` 例外（无线固件）。

## 4. 命令表（已确认）

| 命令 | 方向 | 功能 | 上游位置 |
|------|------|------|----------|
| `0x02` | 写 | 回报率档位码 | `DeviceSettingsCodec.EncodeReportRate` |
| `0x03` | 写 | DPI 档位 | `DpiCodec.EncodeStages` |
| `0x04` | 写 | DPI 各档颜色 | `DeviceSettingsCodec.EncodeDpiColors` |
| `0x05` | 写 | 灯光模式 | `LightCodec.Encode` |
| `0x06` | 写 | 传感器 / 抬升高度 | `DeviceSettingsCodec.EncodeSensorLift` |
| `0x07` | 写 | 休眠 / 移动唤醒 | `DeviceSettingsCodec.EncodeSleep` |
| `0x08` | 写 | 宏内容上传 | `MacroCodec.Encode` |
| `0x09` | 写 | 按键映射 | `KeyMapCodec.Encode` |
| `0x0C`/`0x0D`/`0x0E`/`0x0F` | 复位 | DPI / 回报率 / 灯光 / 出厂 | 各 Codec |
| `0x10` | 读 | 设备信息（固件/IC/电量/在线） | `DeviceInfoCodec` |
| `0x11` | 读 | 会话握手（不解析） | `RealMouseService` |
| `0x12`–`0x17` | 读 | 回报率 / DPI / DPI 色 / 灯光 / 传感器 / 休眠 | `RealMouseService.ReadBackSettings` |
| `0x20` | 读 | 2.4G 无线固件版本 | `RealMouseService` |
| `0x52` | 读 | 原始读 `'R'`（未使用） | `hid-protocol.md` |

## 5. 宏（核心，已有抓包证据）

### 5.1 官方数据库模型

来自原厂 SQLite `mouse_in9(3311)_data1.db`：

| `t_macrorecord.type` | 含义 | `value` |
|----|------|---------|
| 1 | 延时 | 毫秒 |
| 2 | 键盘按下 | Windows VK |
| 3 | 键盘松开 | Windows VK |
| 4 | 鼠标按下 | 按钮位：左 1 / 右 2 / 中 4 |
| 5 | 鼠标松开 | 按钮位 |

延时是**独立记录**，但下发时必须并入前一个动作。

### 5.2 线上格式（`MacroCodec` + 抓包）

每个动作为 4 字节：

```
[动作类型, 延时低字节, 延时高字节, 键值]
```

动作类型：

| 语义 | 类型字节 | 键值 |
|------|----------|------|
| 键盘按下 | `0x30` | HID usage（A → `0x04`） |
| 键盘松开 | `0xB0` | HID usage |
| 修饰键按下 | `0x20` | 修饰位掩码 |
| 修饰键松开 | `0xA0` | 修饰位掩码 |
| 鼠标按下 | `0x10` | 按钮位 |
| 鼠标松开 | `0x90` | 按钮位 |

特殊规则（上游明确复刻）：

- 相邻动作间延时最小 1 ms；末尾延时补到最后一个动作。
- `0x5B`/`0x5D`（Win 键）松开时，官方与按下同为 `0x20`（上游照抄该行为）。
- 宏槽 = **被绑定物理键的下标 `key_code`**，帧内写 `key_code + 1`。

官方抓包（宏「A↓ 50ms A↑」，绑定 6 号键 `key_code=5`）：

```
00 08 00 01 09 06 30 32 00 04 B0 01 00 04 00 ... 21
```

- `buf[4] = 事件数*4 + 1 = 9`
- `buf[5] = 0x06`（槽 5+1）
- `30 32 00 04` = A 按下 + 50ms
- `B0 01 00 04` = A 松开（最小 1ms）
- 校验和 `0x21`

### 5.3 分帧

- ≤ 6 个动作：单帧，`buf[3]=0x01`，`buf[4]=动作数*4+1`，`buf[5]=槽+1`，事件从 `buf[6]` 开始。
- > 6 个动作：`body = [槽+1] + 动作流`，按 27 字节分块；每块 `buf[3] = (块序 << 4) | 总块数`，`buf[4] = 0x1B`（整块）或余数（末块）。

### 5.4 宏绑定（`0x09` 中的 `0x90` 条目）

- `v1` 低半字节 = `key_code + 1`；高半字节为循环标志。
- 标志：按住循环 `|0x10`；直到任意键 `|0x40`；指定次数 `|0x20` 且 `v2 = 次数`；单次无标志。
- 官方抓包：6 号键单次 → `90 26 01`。
- 上传顺序：先 `0x08` 写宏内容，再 `0x09` 写按键映射。

### 5.5 未确认

- 宏**读回**：`0x18`/`0x19`/`0x1A` 均无响应，上游推断设备「只收不回传」。
- 宏槽数量上限、槽与物理键的完整对应（5 键 vs 6 键）未知。
- 分块上传在 > 6 动作时的实机行为未验证。

## 6. 键盘映射编码（`0x09`，已确认）

- 载荷为每个物理键 3 字节 `[功能类型, v1, v2]`；头部长度 = 键数 × 3。
- 功能类型高半字节：`0x10` 鼠标键、`0x20` 滚轮/特殊、`0x30` 连发、`0x40` DPI、`0x60` 系统/配置、`0x70` 键盘键、`0x80` 多媒体、`0x90` 宏。
- 出厂默认载荷（5 键）：`10 01 00 / 10 02 00 / 10 04 00 / 10 08 00 / 10 10 00`。
- 键盘键：`v1 = 修饰掩码`，`v2 = GetSysKeyCode(usage)`；独立修饰键时 `v1 = 修饰位, v2 = 0`。
- 修饰位：LCtrl `0x01`、LShift `0x02`、LAlt `0x04`、LGui `0x08`、RCtrl `0x10`、RShift `0x20`、RAlt `0x40`、RGui `0x80`。

## 7. DPI 换算（已确认，按 `ic_type`）

`Clamp(dpi, 50, 26000)` 后：

| ic_type | 正向 |
|---------|------|
| `0x11` | `dpi>12999: (dpi-13000)/1000+221`；`dpi<10001: dpi/50`；否则 `(dpi-10000)/100+200` |
| `0x05` | `dpi<6401: dpi/50`；否则 `(dpi-6400)/100+128` |
| `0x25` | `dpi>5000: (dpi-5000)/500+50`；否则 `dpi/100` |
| `0x26` | `dpi<5001: dpi/100-1`；否则 `(dpi-5000)/500+50` |
| `0x31` | `dpi>12000: (dpi-12000)/1000+120`；否则 `dpi/100` |
| `0x04/0x10/0x12/0x35` | `dpi/100` |
| 其它 | `dpi/50-1` |

DPI 下发 `0x03`：`buf[4]=0x25`（原厂固定值，不是载荷长度），`buf[5]=(当前档<<4)|档数`，每档 4 字节 `reg_lo, reg_hi, reg_lo, reg_hi`。

## 8. 设备信息（`0x10`，剥掉 report ID 后）

| 偏移 | 含义 |
|------|------|
| `[8..9]` | 固件版本，小端；`0x0142` 显示 `1.42` |
| `[0x0A]` | `ic_type`（决定 DPI 换算、上下限） |
| `[0x0B]` | 回报率档数：`0x10→5`、`0x20→6`、`0x40→7`、其它 4 |
| `[0x0C]` | 充电标志 |
| `[0x0D]` | 电量百分比 |
| `[0x0E]` | 在线标志 |

## 9. 设备识别（Windows）

- 型号目录：USB `VID 0x248A / PID 0x8266 / MI_02`，2.4G `VID 0x249A / PID 0x8266 / MI_02`。
- 上游内置兜底型号名为 `IN9 (内置默认)`，`DeviceAttr = mouse_in9(6827)`；抓包数据库来自 `3311` 型号。**两者不是同一个型号字符串**，不能据此认定 PID 或能力一致。
- 上游用「枚举接口路径是否包含 `vid_xxxx` 与 `pid_xxxx`」做插拔轮询，再按 `mi_02` 选配置接口。

macOS 上必须重新确认：目标 VID/PID 下有几个 IOHIDDevice、哪个是配置接口（`bInterfaceNumber == 2` 或厂商 Usage Page）、输出/输入报告长度是否与 33/30 一致。

## 10. Windows 专属 API 清单（需替换）

| 类别 | Windows API | macOS 替代 |
|------|-------------|------------|
| 枚举 | `SetupDiGetClassDevs`、`SetupDiEnumDeviceInterfaces`、`SetupDiGetDeviceInterfaceDetail`、`SetupDiDestroyDeviceInfoList` | `IOHIDManagerCreate` / `IOHIDManagerSetDeviceMatching` / `IOHIDManagerCopyDevices` |
| 打开 | `CreateFile`（`FILE_FLAG_OVERLAPPED`） | `IOHIDDeviceOpen`（`kIOHIDOptionsTypeNone`，不抢占系统鼠标） |
| 写 | `WriteFile` / hidapi `hid_write` | `IOHIDDeviceSetReport(kIOHIDReportTypeOutput, ...)` |
| 读 | `ReadFile` / `hid_read_timeout` + 重叠 I/O 事件 | `IOHIDDeviceRegisterInputReportCallback` + `CFRunLoopRunInMode` 超时泵 |
| 能力 | `HidD_GetPreparsedData`、`HidP_GetCaps` | `IOHIDDeviceGetProperty(kIOHIDMaxInputReportSizeKey / MaxOutputReportSizeKey)` |
| 字符串 | `HidD_GetProductString`、`HidD_GetAttributes` | `IOHIDDeviceGetProperty(kIOHIDProductKey / VendorID / ProductID)` |
| 接口号 | 接口路径含 `mi_02` | IORegistry `bInterfaceNumber`（Probe 已实现） |
| 定时/轮询 | `System.Threading.Timer`、`Thread.Sleep` | Swift `Task.sleep` / `DispatchSourceTimer` |
| 设置 | `HidD_SetFeature/GetFeature` | `IOHIDDeviceSetReport/GetReport(kIOHIDReportTypeFeature)` |
| 元数据 | 读取原厂安装目录 `config.xml` / `device/*.xml` | 不依赖原厂安装；内置 IN9 参数 + 可选导入 JSON |
| UI/DI | WinUI 3、`Microsoft.Extensions.DependencyInjection` | SwiftUI、手写轻量依赖注入 / `@Observable` |

## 11. 上游内部矛盾与风险记录

1. README 说 91 项测试，NEXT-STEPS 说 88 项；未在本机复跑，不作结论。
2. README 说按键映射为 6 键，`KeyMapCodec.DefaultPayload` 与 header 长度却是 5 键；`0x09` 的 `buf[4]` 在抓包里是 `0x0F`（15 = 5×3）。六键帧只是单测构造，**未实机验证**。
3. `0x03` 的 `buf[4]=0x25` 含义未知，必须原样保留。
4. 回报率「码 = 1000/Hz」是 UI 侧换算，协议文档仍标为待实机确认。
5. 灯光模式 id 与名称的对应部分来自 UI 资源，部分待实机核对。
6. `Apply*` 多处只以 `WriteOk` 为成功；移植时禁止沿用，必须报告 `write / ack / readback / execution` 四态。
7. 上游没有 macOS 侧实现，也没有 report ID 语义、TCC 权限、接口选择的任何验证。

## 12. Phase 1 实测补充（2026-11-09，与上游不同）

在本机真实 2.4G 接收器上只读验证后，确认以下事实（原始帧见 `docs/STATUS.md`）：

| 项 | 上游 | 本机实测 |
|----|------|----------|
| 2.4G PID | `0x8266` | `0x5C2F`（VID 仍为 `0x249A`，接口 2） |
| report ID | hidapi 33 字节写 | `IOHIDDeviceSetReport` 必须 `strip`：32 字节 + `reportID=0`；33 字节无响应 |
| 0x10 载荷长度 | 示例更长 | `0x0B`；字段偏移 `[8..0x0E]` 仍成立 |
| 0x10 载荷前 4 字节 | 未知 | `4D 39 30 39`（"M909"），含义未知 |
| 0x11 | 握手，不解析 | 返回 18 字节 = **6 键按键映射**（5 鼠标键 + `0x40 0x01` DPI） |
| 0x20 | 固件在 `resp[6..7]` | 载荷仅 2 字节 `42 01` → `0x0142`（1.42） |
| DPI 档位 | 上游默认 800/1600/3200/6400/12000/26000 | 本机寄存器 16/32/48/64/130/220 → 800/1600/2400/3200/6500/12000，当前第 3 档 |
| 按键数 | 默认载荷 5 键 | 0x11 读回 6 键（含 DPI 键），与 3311 元数据一致 |

结论：**不能把上游默认值写回设备**；Phase 3 前必须先读回并备份当前配置。0x11 可作为按键映射读回命令（需进一步验证其与 0x09 写入的对应关系）。

## 13. 结论

- 帧格式、校验和、宏事件编码、宏槽约定、按键映射条目、DPI 换算、设备信息解析都有足够证据，可以进入 Swift 协议层移植（Phase 2）。
- report ID 语义、配置接口定位、ACK 读取已在 Phase 1 真机确认：`strip` + 32 字节、`bInterfaceNumber == 2`、`resp[1] == 0`。
- 实机 PID 为 `0x5C2F`（非上游 `0x8266`），0x11 可读回 6 键映射；上游默认值不得直接写回。
- 宏读回、回报率码表、灯光 id、写入类命令仍未验证，UI 不得把它们画成已支持。
