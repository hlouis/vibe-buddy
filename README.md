# Vibe Buddy

按住 M5Stack StickS3 的 A 按钮录音，App 调用豆包流式 ASR 实时转写。macOS 版直接把文字**增量注入当前焦点应用**；iOS / iPadOS 版受系统沙盒限制无法跨 App 注入，改为在 App 内显示并自动写入剪贴板，用户切回目标 App 一次粘贴。

```
[ StickS3 ]  ——按住A录音——>  PCM 流 (BLE 2M PHY)
     |                              |
     +—— 屏幕状态 & 按钮             v
                          ┌─────────────────────┐
                          │  VibeBuddyCore (SPM)│
                          │  BLE / Audio / ASR  │
                          └────────┬────────────┘
                                   │
                  ┌────────────────┴─────────────────┐
                  ▼                                  ▼
          [ macOS App ]                       [ iOS / iPadOS App ]
          CGEvent 增量注入                     UIPasteboard + App 内显示
          (TextEdit / 任意输入框)              (粘贴到目标 App)
```

Phase 1 在 M5Stack StickS3 + 2M PHY + 豆包 `bigmodel` 上验证通过，端到端延迟 <1s。

## 项目结构

```
vibe-buddy/
├── PLAN.md                      # 项目全局设计文档
├── docs/                        # 外部参考资料
│   └── doubao-asr-offical-doc.md
├── firmware/                    # M5Stack StickS3 固件（C++/Arduino）
│   ├── platformio.ini
│   └── src/
│       ├── main.cpp             # 主循环、状态机、屏幕
│       ├── ble_bridge.{h,cpp}   # NUS 服务端、2M PHY/DLE 协商
│       └── recorder.{h,cpp}     # M5.Mic 录音、ping-pong 缓冲、BLE 分包
├── shared/                      # 共享业务逻辑（Swift Package）
│   ├── Package.swift
│   └── Sources/VibeBuddyCore/
│       ├── BLEController.swift  # CoreBluetooth Central、帧分派
│       ├── AudioStreamer.swift  # 200ms 裁剪、累积成 ASR chunk
│       ├── STTService.swift     # 豆包二进制协议 + WebSocket
│       ├── Gzip.swift           # Compression 框架 + 手动 gzip 封装
│       ├── AppState.swift       # 视图模型（@MainActor ObservableObject）
│       ├── Config.swift         # 凭证存储（macOS=XDG，iOS=UserDefaults）
│       └── TextHandler.swift    # 跨平台文字处理协议
├── macos-app/                   # macOS 应用（Swift/SwiftUI）
│   ├── project.yml              # xcodegen 生成 xcodeproj 的唯一真相源
│   └── VibeBuddy/
│       ├── VibeBuddyApp.swift   # @main，注入 TextInjector
│       ├── ContentView.swift    # 主窗口 UI
│       └── TextInjector.swift   # CGEvent 增量注入 + 最长公共前缀 diff
├── ios-app/                     # iOS / iPadOS 应用（Swift/SwiftUI）
│   ├── project.yml              # universal: TARGETED_DEVICE_FAMILY=1,2
│   └── VibeBuddy/
│       ├── VibeBuddyApp.swift   # @main，注入 PasteboardHandler
│       ├── ContentView.swift    # 主界面 + 设置 sheet（iPhone+iPad 自适应）
│       └── PasteboardHandler.swift # UIPasteboard + 应用内 buffer
└── tools/
    └── ble_audio_dump.py        # 纯 BLE 端到端验证脚本（bleak 客户端）
```

## 硬件

**M5Stack StickS3**（SKU K150）
- ESP32-S3-PICO-1-N8R8（8 MB flash + 8 MB OPI PSRAM）
- 1.14" LCD · MEMS mic 经 ES8311 codec · BMI270 · AXP2101 PMU
- BLE 5.0（支持 2M PHY + DLE）

## 构建前一次性准备

```bash
# 1. PlatformIO（固件）
brew install platformio

# 2. xcodegen（macOS 工程生成器）
brew install xcodegen

# 3. 确保 xcodebuild 指向完整 Xcode，不是 CLT
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept

# 4. 豆包 ASR 凭证（放到 XDG 路径，不进仓库）
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vibe-buddy"
mkdir -p "$CFG_DIR"
cat > "$CFG_DIR/config.json" <<'EOF'
{
  "app_id": "你的火山 App ID",
  "access_token": "你的 Access Token / API Key",
  "resource_id": "volc.bigasr.sauc.duration"
}
EOF
chmod 600 "$CFG_DIR/config.json"
```

凭证在 [火山引擎控制台 · 语音技术](https://console.volcengine.com/speech/service/16) 开通 "大模型流式语音识别" 后获取。本项目两种鉴权方式都兼容：

- 双 header：`X-Api-App-Key` + `X-Api-Access-Key`
- 单 header：`X-Api-Key`（把 token 填到 `access_token` 字段即可）

## 构建与运行

### 固件

```bash
cd firmware
pio run -e m5stack-sticks3 -t upload     # 编译并烧录
pio device monitor -b 115200             # 串口日志
```

连接设备：USB-C 数据线连 Mac。首次烧录如找不到串口，`ls /dev/cu.*` 看设备名。

### macOS App

```bash
cd macos-app
xcodegen generate
open VibeBuddy.xcodeproj
# 在 Xcode 里 Cmd+R 运行
```

首次启动：
1. 系统会弹 **蓝牙权限**请求 → 允许
2. App 会提示 **Accessibility 权限** → 去系统设置 → 隐私与安全性 → 辅助功能 → 把 VibeBuddy 加进去并打勾 → 回到 App 重启一次

### iOS / iPadOS App

```bash
cd ios-app
xcodegen generate
open VibeBuddy.xcodeproj
# 在 Xcode 里选择 iPhone / iPad 真机，Cmd+R
```

iOS 版与 macOS 版共享 `shared/` 下的 BLE / Audio / ASR 业务逻辑。三个 tab：

- **转写 tab**:剪贴板模式。实时转写显示在 App 内,自动复制到剪贴板,切到任何其他 App 长按粘贴
- **浏览器 tab**:WebView 模式。内嵌 WKWebView + 预设书签(Claude / ChatGPT / 豆包 / Kimi / DeepSeek / 通义)。ASR 文字直接 `evaluateJavaScript` 注入到当前焦点的 `<input>` / `<textarea>` / `[contenteditable]`。同时仍写剪贴板兜底
- **设置 tab**:豆包凭证 + 书签管理

iOS 限制说明:
- 系统不允许 inter-app 键盘注入,所以 macOS 版的"自动打字到任意 App"在 iOS 端做不到。WebView 模式是这个能力在 iOS 上的最近替代 —— 仅在 App 内嵌的网页有效
- 凭证存储用 UserDefaults(后续会迁到 Keychain)
- 后台保活通过 Info.plist 的 `bluetooth-central` background mode;切到其他 App 粘贴时 GATT 不掉
- Gemini 暂不支持(Google OAuth 拒绝在 WKWebView 中登录)

首次启动:
1. 系统弹 **蓝牙权限** → 允许
2. 切到"设置"tab → 填入豆包 App ID / Access Token / Resource ID → 保存
3. 切到"浏览器"tab → 选 Claude(或其他书签)→ 登录一次 → 输入框点一下获得焦点 → 按住设备 A 按钮说话

### 验证流程

1. 给 StickS3 上电，屏幕显示 `VibeBuddy-XXXX` + 黄色 `advertising`
2. 启动 VibeBuddy macOS App，几秒内屏幕转绿色 `link: 2M mtu=517`
3. 在 Mac 上打开 **TextEdit** → 新建空白文档 → 保持焦点
4. 按住设备 A 按钮说中文 5–10 秒
5. VibeBuddy 窗口里能看到蓝色 partial 文字实时滚动，TextEdit 同步出字
6. 松开 A → 1 秒内文字稳定为黑色 final 结果

## 调试工具

### 纯 BLE 验证（不走豆包）

用 Python 脚本直接抓 BLE 音频流落 PCM，绕开 Mac App 和 ASR：

```bash
python3 -m venv tools/.venv
tools/.venv/bin/pip install bleak
tools/.venv/bin/python tools/ble_audio_dump.py
# 按住 A 录一段，松开后：
ffmpeg -y -f s16le -ar 16000 -ac 1 -i out.pcm out.wav && afplay out.wav
```

### 固件日志

```bash
pio device monitor -b 115200 -d firmware
```

关键标签：`[boot]` / `[ble]` / `[link]` / `[rec]` / `[mic]` / `[tick]` / `[rec-tick]`

### macOS 日志

```bash
log stream --predicate 'process == "VibeBuddy"' --style compact
```

关键标签：`[ble]` / `[json]` / `[audio]` / `[stt]`

## 关键设计决策

BLE 协议、帧格式、协商参数等详见 [`PLAN.md`](PLAN.md)。几处踩坑经验：

- StickS3 的扬声器与麦克风共享 ES8311，用 `cfg.internal_spk = false` 释放 I2S
- M5Unified 的 `M5.Mic.record()` 异步 API 用单缓冲会产生 chunk 重复 → 用 ping-pong
- BLE 默认 LL PDU 27 字节会把 500 B notify 拆 20 段，必须显式调 `esp_ble_gap_set_prefered_default_phy` + `esp_ble_gap_set_pkt_data_len(251)`
- iOS 默认 connection interval 可能给 30ms，主动 `esp_ble_gap_update_conn_params` 请求 7.5–15ms
- 豆包协议每帧都带 4 字节 seq（文档里没写清），最后一帧用**负数** seq + flag `0x3`
- 豆包鉴权 header 名是 `X-Api-Request-Id`（不是文档里的 `X-Api-Connect-Id`）

## 许可

待定。

## 路线图

Phase 1（已完成）：按住录音 → 流式 ASR → 增量注入，端到端走通。

Phase 2（计划中）：
- Claude 权限申请的硬件审批流
- 文字编辑辅助模式（双击换行、BtnB backspace）
- BLE 加密配对
- 屏幕菜单与设置页
- Keychain 凭证管理
