# Vibe Buddy — 项目设计文档

> 本文档是交给 Claude Code 构建两个子项目的完整技术规格。
> 所有架构决策、协议定义、硬件信息均已在此文档中确定，构建时无需再做任何协议层面的决策。

---

## 0. 项目概述

**目标**：按住 M5Stack StickS3 的 A 按钮录音，音频边录边通过 BLE 流式传输到 macOS App，
Mac App 调用豆包流式 ASR，实时将识别文字（含中间结果）注入到当前焦点应用，
同时支持 Claude 权限申请的硬件审批。

**子项目**：

| 子项目 | 语言/框架 | 说明 |
|---|---|---|
| `firmware/` | C++ / Arduino + PlatformIO | M5Stack StickS3 固件 |
| `shared/` | Swift Package（VibeBuddyCore） | BLE / Audio / Doubao ASR / 状态机；macOS+iOS 共用 |
| `macos-app/` | Swift / SwiftUI | macOS 应用，CGEvent 文字注入 |
| `ios-app/` | Swift / SwiftUI | iOS / iPadOS 通用 App，UIPasteboard 暂存 |

跨平台拆分原则：业务逻辑（CoreBluetooth、音频流帧化、豆包二进制协议、AppState）放在 `shared/`，平台相关的"文字落点"通过 `TextHandler` 协议注入 —— macOS 实现是 `TextInjector`（CGEvent 增量键入），iOS 实现是 `PasteboardHandler`（写 UIPasteboard + App 内显示）。iOS 无法跨 App 注入键盘是 Apple 沙盒硬限制，无法绕过。

---

## 1. 硬件规格

**设备**：M5Stack StickS3（SKU: K150）

| 参数 | 值 |
|---|---|
| 主控 | ESP32-S3-PICO-1-N8R8 |
| Flash | 8MB |
| PSRAM | 8MB（OPI 接口） |
| 显示 | 1.14" LCD（135×240） |
| 麦克风 | MEMS 麦克风，经 **ES8311** 单声道 codec 驱动 |
| 扬声器 | AW8737 功放 |
| IMU | BMI270（6轴） |
| 蓝牙 | **BLE 5.0（支持 2M PHY）** |
| 电池 | 250mAh 锂电池 |
| 按钮 | BtnA（正面）、BtnB（右侧） |
| 电源管理 | AXP2101 PMU |

**关键音频硬件说明**：
StickS3 的麦克风通过 **ES8311 codec 芯片**（I2C 配置、I2S 传输）。
M5Unified 的 `M5.Mic` API 已完整封装此硬件，固件中**直接使用 M5Unified 的 Mic 类**，
无需手动操作 GPIO 或 I2S 寄存器。

---

## 2. 固件项目（`firmware/`）

### 2.1 构建配置

**`platformio.ini`**：

```ini
[env]
framework = arduino
monitor_speed = 115200
build_flags =
    -DCORE_DEBUG_LEVEL=0
lib_deps =
    m5stack/M5Unified
    m5stack/M5GFX
    bblanchon/ArduinoJson @ ^7.0.0

[env:m5stack-sticks3]
platform = espressif32@6.12.0
board = esp32-s3-devkitc-1
board_build.partitions = huge_app.csv
board_build.arduino.memory_type = qio_opi
build_flags =
    ${env.build_flags}
    -DESP32S3
    -DBOARD_HAS_PSRAM
    -mfix-esp32-psram-cache-issue
    -DARDUINO_USB_CDC_ON_BOOT=1
    -DARDUINO_USB_MODE=1
lib_deps =
    ${env.lib_deps}
```

**说明**：

- `huge_app.csv`：Arduino-ESP32 内置的大 app 分区表（app 分区 ~3MB），对 Vibe Buddy 足够；需要 OTA 再换
- `qio_opi`：S3 的 PSRAM 是 OPI 接口，必须指定，否则 PSRAM 初始化失败
- **AXP2101 电源管理已由 M5Unified 内置支持**（`M5.Power`），不需要额外库
- BLE 和 I2S 驱动均为 Arduino ESP32 内置，无需额外 `lib_deps`

### 2.2 源文件结构

```
firmware/
├── platformio.ini
└── src/
    ├── main.cpp          # 主循环、状态机、屏幕渲染
    ├── ble_bridge.cpp    # NUS BLE 服务端（参考 claude-desktop-buddy）
    ├── ble_bridge.h
    ├── recorder.cpp      # 麦克风录音 + 音频分包发送
    ├── recorder.h
    └── data.h            # 协议常量、JSON 解析（参考 claude-desktop-buddy）
```

**不做持久化**：第一期设备端无任何设置需要跨启动保存（API Key 在 Mac Keychain，
亮度/方向等设置不做），不引入 NVS。

### 2.3 状态机

```
STATE_SLEEP      BLE 未连接
STATE_IDLE       已连接，待机
STATE_RECORDING  录音中（按住 A）
STATE_BUSY       Mac 端正在处理（STT 流式进行中）
STATE_PERMISSION 有 Claude 权限申请待处理
STATE_EDIT       编辑辅助模式（STT 注入后 5 秒内）
```

**按钮行为矩阵**：

| 状态 | BtnA 按下 | BtnA 松开 | BtnA 长按 | BtnA 双击 | BtnB 短按 |
|---|---|---|---|---|---|
| IDLE | 进入 RECORDING | — | 菜单 | — | — |
| RECORDING | — | 停止并发送 stop | — | — | 取消录音（不发送） |
| BUSY | — | — | — | — | — |
| PERMISSION | Approve | — | — | — | Deny |
| EDIT | 进入 RECORDING（取消编辑模式） | — | 退出编辑模式 | 发送换行 | Backspace |

**按键判定细节**：

- 录音触发 = BtnA 按下即进入 RECORDING（不等消抖判"短按/长按"）
- EDIT 模式下按 A 有冲突（短按录音 vs 双击换行）：采用 **按下即开始录音，若 300ms 内再次点击则取消该录音并改执行换行**。代价是偶尔录到 <300ms 垃圾音频被丢弃，属可接受。
- 双击窗口 300ms，长按阈值 800ms

### 2.4 录音参数

| 参数 | 主档 | 降级档 |
|---|---|---|
| 采样率 | **16000 Hz** | 8000 Hz |
| 位深 | 16-bit | 16-bit |
| 声道 | Mono | Mono |
| 码率 | 32 KB/s | 16 KB/s |
| 使用 API | `M5.Mic.record()` | 同 |

**档位选择**：固件在 BLE 连接建立后尝试协商 **2M PHY**。
- 成功 → 使用 16kHz 主档
- 失败 → 使用 8kHz 降级档

实际档位通过 `audio/start` 事件中的 `sample_rate` 字段告知 Mac 端。

**录音硬上限**：60 秒。到点强制 stop（防按键卡住、口袋误触、BLE 缓冲溢出）。正常 push-to-talk 不会触及。

**PSRAM 使用**：不需要全量缓存。仅维护一个 **32 KB 环形缓冲**（约 500ms @ 16kHz）作为 BLE 发送队列的抗抖动 buffer。

---

## 3. BLE 通信协议

### 3.1 BLE 服务定义

复用 **Nordic UART Service (NUS)**，与 claude-desktop-buddy 协议兼容：

```
NUS Service UUID:  6E400001-B5A3-F393-E0A9-E50E24DCCA9E
RX Characteristic: 6E400002-B5A3-F393-E0A9-E50E24DCCA9E  [Write]    Mac → Device
TX Characteristic: 6E400003-B5A3-F393-E0A9-E50E24DCCA9E  [Notify]   Device → Mac
```

设备广播名称格式：`VibeBuddy-XXXX`（XXXX 为 BT MAC 后 4 位十六进制，用 `esp_read_mac(..., ESP_MAC_BT)` 获取）。

### 3.2 连接参数协商（关键）

连接建立后固件立即执行：

1. **请求 2M PHY**：`esp_ble_gap_set_preferred_phy(..., ESP_BLE_GAP_PHY_2M_PREF_MASK, ESP_BLE_GAP_PHY_2M_PREF_MASK, ...)`。失败不阻塞，使用 1M PHY 跑降级档。
2. **请求 ATT MTU 提升**：`BLEDevice::setMTU(247)` 或更高（Mac 侧通常接受到 185–247）。
3. **请求 Data Length Extension (DLE)**：通过 `esp_ble_gap_set_pkt_data_len(...)` 或由 MTU 请求自动触发。
4. 实际协商结果通过 `phy/update` 事件上报 Mac：

```jsonc
{"type": "link", "phy": "2M", "mtu": 247}
```

### 3.3 帧格式

NUS 上承载两种帧：

**JSON 帧（文本控制消息）**：

```
[UTF-8 JSON bytes] + ['\n']
```

JSON 对象以换行符 `\n` 终止，Mac 端以此分帧（BLE MTU 分包后重组）。

**音频二进制帧**：

```
┌──────┬──────┬──────────────┬──────────────┬──────────────────────────┐
│ 0xFF │ 0xAA │  seq [2B LE] │  len [2B LE] │   PCM data (≤MTU-6)      │
└──────┴──────┴──────────────┴──────────────┴──────────────────────────┘
```

- 魔数 `0xFF 0xAA`：区分音频帧与 JSON 帧（JSON 首字节为 `{`，永远不为 `0xFF`）
- `seq`：小端序包序号，**每次 `audio/start` 从 0 重置**，用于 Mac 端检测丢包
- `len`：小端序有效 PCM 数据长度（字节）
- PCM data：原始 16-bit 小端序 PCM；单帧最大长度 = 协商 MTU − 3（ATT header）− 6（帧头）

**丢包处理**：Mac 端发现 seq 跳号时，记录日志并用零填充丢失段（流式 ASR 对短暂静音容忍度高），不做重传（NUS 无重传能力且实时场景无意义）。

### 3.4 下行消息（Mac → Device）

完全复用 claude-desktop-buddy 的消息格式：

```jsonc
// 心跳 / 状态同步（Mac 定期发送，约每 2 秒一次）
{
  "sessions": 1,
  "input_tokens": 12500,
  "output_tokens": 3200,
  "has_prompt": false,
  "prompt": null
}

// 有权限申请时的心跳
{
  "sessions": 1,
  "input_tokens": 12500,
  "output_tokens": 3200,
  "has_prompt": true,
  "prompt": {
    "id": "abc123",
    "tool": "bash",
    "description": "rm -rf dist/"
  }
}

// STT 处理状态反馈（设备据此切换 BUSY / EDIT 状态）
{"type": "stt", "event": "partial", "text": "帮我查"}
{"type": "stt", "event": "final",   "text": "帮我查一下库存"}
{"type": "stt", "event": "error",   "message": "network timeout"}
```

### 3.5 上行消息（Device → Mac）

**权限决策**（复用 claude-desktop-buddy 格式）：

```jsonc
{"action": "approve", "prompt_id": "abc123"}
{"action": "deny",    "prompt_id": "abc123"}
```

**文字编辑**：

```jsonc
{"type": "edit", "action": "backspace"}
{"type": "edit", "action": "newline"}
```

**录音控制**：

```jsonc
{"type": "audio", "event": "start", "sample_rate": 16000}
{"type": "audio", "event": "stop"}
{"type": "audio", "event": "cancel"}   // BtnB 取消，Mac 应丢弃该会话缓冲并通知 ASR 中止
```

**链路状态**：

```jsonc
{"type": "link", "phy": "2M", "mtu": 247}
```

音频数据帧：见 3.3 节二进制帧格式（不走 JSON，直接发二进制）。

---

## 4. macOS App（`macos-app/`）

### 4.1 项目配置

- **语言**：Swift 6
- **UI 框架**：SwiftUI
- **应用类型**：普通窗口应用（`NSApplicationActivationPolicy.regular`），有 Dock 图标
- **最低系统要求**：macOS 14.0（Sonoma）
- **Bundle ID**：`com.yourname.vibebuddy`（按需修改）

**Info.plist 必要权限**：

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>需要蓝牙连接 Vibe Buddy 设备</string>
```

**Accessibility 授权**（文字注入依赖）：
- **不通过 Info.plist 声明**（Accessibility 无对应 usage key）
- 首次启动检查 `AXIsProcessTrusted()`，未授权时弹窗引导用户到
  System Settings → Privacy & Security → Accessibility 手动勾选

**Signing & Capabilities**：开启 `Bluetooth` capability。

### 4.2 源文件结构

```
macos-app/
├── VibeBuddy.xcodeproj
└── VibeBuddy/
    ├── VibeBuddyApp.swift      # App 入口
    ├── ContentView.swift        # 主窗口 UI
    ├── BLEManager.swift         # CoreBluetooth Central，连接/收发数据
    ├── AudioStreamer.swift      # 接收音频帧，推送给 STTService
    ├── STTService.swift         # 豆包流式 ASR WebSocket 封装
    ├── TextInjector.swift       # Accessibility API 文字注入 + 增量 diff
    ├── PermissionManager.swift  # 权限申请 UI 逻辑
    ├── Keychain.swift           # API Key 存取
    └── Models.swift             # 数据模型、状态枚举
```

### 4.3 BLE 接入（BLEManager.swift）

使用 `CoreBluetooth` 框架：

```
CBCentralManager
  → 扫描广播名以 "VibeBuddy-" 开头的设备
  → 连接后发现 NUS Service + RX/TX Characteristic
  → 订阅 TX Characteristic Notify
  → 分帧：以 '\n' 分隔 JSON 帧；首字节 0xFF && 次字节 0xAA → 音频帧
  → JSON 帧 dispatch 到对应处理器；音频帧推送给 AudioStreamer
```

**MTU / PHY**：macOS 的 CoreBluetooth 不暴露 PHY 控制，但 Central 会接受 Peripheral 发起的
2M PHY 请求。MTU 可通过 `peripheral.maximumWriteValueLength(for:)` 读取。

### 4.4 音频流接收（AudioStreamer.swift）

- 收到 `{"type":"audio","event":"start","sample_rate":N}` 时：
  1. 用 `sample_rate` 启动 `STTService` 的 WebSocket 会话
  2. 重置 `seq` 检测计数
- 收到音频二进制帧：
  1. 按 seq 检测丢包（跳号时往 ASR 流推送等长静音）
  2. 将 PCM 数据直接 **流式推送** 给 `STTService`（不做本地 WAV 封装）
- 收到 `{"type":"audio","event":"stop"}` 时：通知 `STTService` 结束音频流，等待 final 结果
- 收到 `{"type":"audio","event":"cancel"}` 时：中止 `STTService` 会话并回滚已注入的中间结果（见 4.6）

### 4.5 STT 服务（STTService.swift）

**第一期仅支持豆包（火山引擎）流式 ASR**。

- Endpoint：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel`
- 协议：豆包二进制协议（gzip + 自定义帧头），参考豆包 ASR SDK 文档
- API Key / App ID：macOS Keychain 存储，首次使用时通过设置界面配置

接口：

```swift
protocol STTServiceDelegate: AnyObject {
    func sttDidReceivePartial(_ text: String)
    func sttDidReceiveFinal(_ text: String)
    func sttDidError(_ error: Error)
}

class STTService {
    func startSession(sampleRate: Int) throws
    func pushAudio(_ pcm: Data)
    func endSession()
    func cancelSession()
}
```

收到 partial / final 后：
1. 回传给 `BLEManager` 发送 `{"type":"stt","event":"..."}` 给设备
2. 调用 `TextInjector` 执行增量注入

### 4.6 文字注入（TextInjector.swift）—— 核心难点

**目标**：实时将流式 ASR 的 partial/final 结果注入焦点应用，支持 ASR 中途修正已吐出的文字。

**核心挑战**：豆包流式返回的 `partial` 文本会**覆盖更新**。例如：
```
t=0.5s  partial="帮我查"
t=1.0s  partial="帮我查一下"
t=1.5s  partial="帮我查一下库"
t=2.0s  final  ="帮我查一下库存"
```
但也可能发生修正：
```
t=0.5s  partial="白云查"     ← 已注入 3 字
t=1.0s  partial="帮我查"     ← 需要 backspace 3 次，重新 type 3 字
```

**增量注入算法**（`TextInjector` 内部维护 `injectedText: String`）：

```
on new ASR text `newText`:
    commonPrefixLen = longestCommonPrefix(injectedText, newText).count
    backspaceCount  = injectedText.count - commonPrefixLen
    toType          = newText.suffix(from: commonPrefixLen)

    for _ in 0..<backspaceCount: sendBackspace()
    typeText(String(toType))
    injectedText = newText

on session end (final 已处理) or session cancel:
    # cancel 时：回滚整个 injectedText
    if cancelled:
        for _ in 0..<injectedText.count: sendBackspace()
    injectedText = ""
```

**实现要点**：

- 首先检查 `AXIsProcessTrusted()`，未授权弹引导窗
- 使用 `CGEvent(keyboardEventSource:virtualKey:keyDown:)` 合成键盘事件
- 汉字等 Unicode 字符使用 `CGEventKeyboardSetUnicodeString`，不依赖 keyCode 映射（避免输入法干扰）
- Backspace 使用 `kVK_Delete` (virtualKey = 0x33)
- 每个字符 keyDown/keyUp 之间加 **2ms 延迟**，防止目标应用丢字
- **节流**：partial 更新频率可能高（50–100ms 一次），如果上次注入未完成（CGEvent 队列未清空），跳过本次 partial 等下一次。final 事件永不跳过。
- **IME 干扰警告**：某些应用（特别是浏览器富文本编辑器）对快速 backspace + unicode type 序列处理不稳。第一期不做特殊处理，出问题记入 known issues。

### 4.7 主界面（ContentView.swift）

SwiftUI 主窗口：

```
┌─────────────────────────────────────────┐
│  Vibe Buddy                        [⚙]  │
├─────────────────────────────────────────┤
│  设备状态: ● 已连接  VibeBuddy-A3F2      │
│  链路:    2M PHY · MTU 247              │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  权限申请                        │    │
│  │  工具: bash                      │    │
│  │  命令: rm -rf dist/              │    │
│  │  [  通过  ]      [  拒绝  ]      │    │
│  └─────────────────────────────────┘    │
│                                         │
│  上次识别结果:                           │
│  "帮我查一下库存状态"                    │
│                                         │
│  豆包 API: ● 已配置                     │
└─────────────────────────────────────────┘
```

权限申请弹窗：收到 `has_prompt: true` 时以 sheet 或 overlay 方式展示，
不自动关闭，等待用户在 Mac 端或设备端操作后消失。

设置页（齿轮图标）：配置豆包 App ID / Access Token / Cluster，保存到 Keychain。

---

## 5. 参考资源

- **claude-desktop-buddy**：`ble_bridge.cpp`、`data.h` 可直接参考或复制（**不要抄 stats.h**，那是电子宠物逻辑，与 Vibe Buddy 无关）
  - 仓库：<https://github.com/imliubo/claude-desktop-buddy/tree/feat/migrate-to-m5unified>
  - BLE 协议完整规范：`REFERENCE.md`
- **M5Stack StickS3 文档**：<https://docs.m5stack.com/en/core/StickS3>
- **M5Unified Mic API**：<https://docs.m5stack.com/en/arduino/m5sticks3/mic>
- **豆包流式 ASR 文档**：<https://www.volcengine.com/docs/6561/1168817>
- **ESP32 BLE 2M PHY / DLE**：<https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/api-reference/bluetooth/esp_gap_ble.html>

---

## 6. 实现顺序建议

每步可独立验证。

**固件端**：

1. 搭建 PlatformIO 项目，跑通 Hello World（屏幕显示 + 串口输出）
2. 实现按钮检测（BtnA 按下/松开/长按/双击，BtnB 短按）
3. 集成 BLE NUS 服务（参考 ble_bridge.cpp），验证 Mac 能连接并收到 JSON
4. **协商 2M PHY + DLE + MTU**，上报 `link` 事件
5. 实现麦克风录音（M5.Mic），验证 PCM 数据采集正常
6. 实现音频分包发送（二进制帧 + 环形缓冲）
7. 完整状态机联调（IDLE/RECORDING/BUSY/PERMISSION/EDIT）

**macOS 端**：

1. 搭建 SwiftUI 项目，实现 CoreBluetooth 扫描和连接
2. 实现 NUS 数据收发 + 分帧，验证与固件的 JSON 通信
3. 实现音频帧接收（seq 检测、丢包补零）
4. 接入豆包流式 ASR WebSocket，打通端到端 partial/final 流
5. 实现 `TextInjector` 增量注入算法（先在 TextEdit 中验证 common-prefix diff + backspace 正确性）
6. 权限申请 UI + Keychain 设置页
7. 完整流程联调
