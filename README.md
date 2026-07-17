# Vibe Buddy

按住 M5Stack StickS3 的 A 按钮录音，App 调用豆包流式 ASR 实时转写。macOS 版直接把文字**增量注入当前焦点应用**；iOS / iPadOS 版受系统沙盒限制无法跨 App 注入，改为在 App 内显示并自动写入剪贴板，或者通过内嵌 WebView 注入到当前焦点的网页输入框。

```
[ StickS3 ]  ——按住A录音——>  PCM 流 (BLE 2M PHY)
     |                              |
     +—— 屏幕状态 & 电量              v
                          ┌─────────────────────┐
                          │  VibeBuddyCore (SPM)│
                          │  BLE / Audio / ASR  │
                          └────────┬────────────┘
                                   │
                  ┌────────────────┴─────────────────┐
                  ▼                                  ▼
          [ macOS App ]                       [ iOS / iPadOS App ]
          CGEvent 增量注入                     UIPasteboard + WebView 注入
          (TextEdit / 任意输入框)              (粘贴 / 网页 input)
```

Phase 1 在 M5Stack StickS3 + 2M PHY + 豆包 `bigmodel` 上验证通过，端到端延迟 <1s。

## 项目结构

```
vibe-buddy/
├── Makefile                        # 顶层命令入口（make / make gen / make build / ...）
├── VibeBuddy.xcworkspace           # 顶层 workspace（macOS + iOS + Core）
├── docs/                           # 外部参考资料
│   └── doubao-asr-offical-doc.md
├── firmware/                       # M5Stack StickS3 固件（C++/Arduino）
│   ├── platformio.ini
│   └── src/
│       ├── main.cpp                # 主循环、状态机、屏幕、电量进度条
│       ├── ble_bridge.{h,cpp}      # NUS 服务端、2M PHY/DLE 协商
│       └── recorder.{h,cpp}        # M5.Mic 录音、ping-pong 缓冲、BLE 分包
├── shared/                         # 共享业务逻辑（Swift Package）
│   ├── Package.swift
│   └── Sources/VibeBuddyCore/
│       ├── BLEController.swift     # CoreBluetooth Central、帧分派
│       ├── AudioStreamer.swift     # 200ms 裁剪、累积成 ASR chunk
│       ├── STTService.swift        # 豆包二进制协议 + WebSocket
│       ├── Gzip.swift              # Compression 框架 + 手动 gzip 封装
│       ├── AppState.swift          # 视图模型（@MainActor ObservableObject）
│       ├── Config.swift            # 凭证存储（macOS=XDG，iOS=UserDefaults）
│       └── TextHandler.swift       # 跨平台文字处理协议
├── macos-app/                      # macOS 应用
│   ├── project.yml                 # xcodegen 生成 xcodeproj 的唯一真相源
│   ├── Local.xcconfig.example      # 模板：DEVELOPMENT_TEAM 等签名设置
│   └── VibeBuddy/
│       ├── VibeBuddyApp.swift      # @main，注入 TextInjector
│       ├── ContentView.swift       # 主窗口 UI
│       └── TextInjector.swift      # CGEvent 增量注入 + 最长公共前缀 diff
├── ios-app/                        # iOS / iPadOS 应用（universal）
│   ├── project.yml                 # TARGETED_DEVICE_FAMILY=1,2
│   ├── Local.xcconfig.example      # 模板：DEVELOPMENT_TEAM 等签名设置
│   ├── VibeBuddy/
│   │   ├── VibeBuddyApp.swift      # @main，构建三 tab 架构
│   │   ├── ContentView.swift       # TabView 容器
│   │   ├── TranscriptTabView.swift # 转写 tab（剪贴板模式）
│   │   ├── SettingsTabView.swift   # 凭证 + 书签管理
│   │   ├── TextRouter.swift        # 在 PasteboardHandler / WebViewInjector 间路由
│   │   ├── PasteboardHandler.swift # UIPasteboard + 应用内 buffer
│   │   └── WebView/
│   │       ├── BrowserState.swift  # @Observable，持有 iOS 26 WebPage
│   │       ├── BrowserTabView.swift# 浏览器 tab UI（地址栏 / 工具栏 / 状态条）
│   │       ├── BookmarkStore.swift # 书签持久化
│   │       ├── InjectionScript.swift  # 焦点跟踪 / 增量注入 / 键盘抑制 JS
│   │       └── WebViewInjector.swift  # 通过 WebPage.callJavaScript 应用 diff
│   └── VibeBuddyTests/             # 单元测试基线（~80 用例）
└── tools/
    └── ble_audio_dump.py           # 纯 BLE 端到端验证脚本（bleak 客户端）
```

## 硬件

**M5Stack StickS3**（SKU K150）
- ESP32-S3-PICO-1-N8R8（8 MB flash + 8 MB OPI PSRAM）
- 1.14" LCD · MEMS mic 经 ES8311 codec · BMI270 · AXP2101 PMU
- BLE 5.0（支持 2M PHY + DLE）

固件屏幕右上角显示电量进度条 + 百分比数字，充电时叠加闪电图标。

## 构建前一次性准备

```bash
# 1. 工具链
brew install platformio       # 固件构建 / 烧录
brew install xcodegen         # macOS / iOS xcodeproj 生成器
brew install xcbeautify       # xcodebuild 输出美化（make build* / make test* 依赖）

# 2. 确保 xcodebuild 指向完整 Xcode（iOS 26 SwiftUI WebView 需要 Xcode 17+）
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept

# 3. 各人签名设置（gitignored，逐人填）
cp macos-app/Local.xcconfig.example macos-app/Local.xcconfig
cp ios-app/Local.xcconfig.example   ios-app/Local.xcconfig
# 编辑两份 Local.xcconfig，把 DEVELOPMENT_TEAM = YOUR_TEAM_ID_HERE
# 改成你自己的 10 字符 Apple Team ID（Xcode > Settings > Accounts 看）。
# xcodeproj 是 gitignored 的，每次 `make gen` 都会重写——把 Team 放在
# Local.xcconfig 里就不会被冲掉，并且 macOS 上 Accessibility 权限授权
# 也不会在重新生成后失效。

# 4. 豆包 ASR 凭证（放到 XDG 路径，不进仓库；macOS 端读取）
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

凭证在 [火山引擎控制台 · 语音技术](https://console.volcengine.com/speech/service/16) 开通"大模型流式语音识别"后获取。两种鉴权方式都兼容：

- 双 header：`X-Api-App-Key` + `X-Api-Access-Key`
- 单 header：`X-Api-Key`（把 token 填到 `access_token` 字段即可）

iOS 端凭证目前走 `UserDefaults`（后续会迁到 Keychain），首次启动从设置 tab 填入即可，不需要 XDG 文件。

## 系统要求

| 端 | 最低版本 | 说明 |
|---|---|---|
| 固件 | — | M5Stack StickS3，PlatformIO @6.12.0+ |
| macOS App | macOS 14（Sonoma） | CoreBluetooth + Accessibility |
| iOS App | **iOS 26 / iPadOS 26** | 依赖 SwiftUI 原生 `WebView` / `WebPage` API |

iOS 端 WebView tab 已迁移到 iOS 26 的 SwiftUI 原生 WebView/WebPage（不再使用 `WKWebView` + `UIViewRepresentable`），所以最低版本卡到 iOS 26。如果需要在更低版本上跑，需要回退到 WKWebView 实现。

## 构建与运行

日常命令统一收在根目录的 `Makefile`，敲 `make` 看菜单：

```
make            # 列出全部 target
make gen        # 同时重生成 macos / ios xcodeproj
make build      # 同时编译 macos / ios（Debug）
make build-macos / make build-ios
make fw-upload  # 编译并烧录固件
make fw-monitor # 串口日志
make test       # SwiftPM + iOS Simulator 全部单测
make open       # 打开 VibeBuddy.xcworkspace
make clean
```

每个 target 旁边标了所需工具（`needs: xcodegen` / `xcbeautify` / `platformio`）；没装就报错，按提示 `brew install` 即可。

### 固件

```bash
make fw-upload      # 编译 + 烧录
make fw-monitor     # 串口日志（115200，标签：[boot] [ble] [link] [rec] [mic] [tick]）
```

连接设备：USB-C 数据线连 Mac。首次烧录如找不到串口，`ls /dev/cu.*` 看设备名。

### macOS App

```bash
make gen-macos      # 一次性，project.yml 改了再跑
make open           # 打开 workspace，在 Xcode 里 Cmd+R（scheme: VibeBuddy-macOS）
# 或者纯 CLI：
make build-macos
```

首次启动：
1. 系统会弹**蓝牙权限**请求 → 允许
2. App 会提示 **Accessibility 权限** → 去系统设置 → 隐私与安全性 → 辅助功能 → 把 VibeBuddy 加进去并打勾 → 回到 App 重启一次

### iOS / iPadOS App

```bash
make gen-ios        # 一次性，project.yml 改了再跑
make open           # 打开 workspace，在 Xcode 里选真机/模拟器 Cmd+R（scheme: VibeBuddy-iOS）
```

iOS 版与 macOS 版共享 `shared/` 下的 BLE / Audio / ASR 业务逻辑。三个 tab：

- **转写 tab**：剪贴板模式。实时转写显示在 App 内，自动复制到剪贴板，切到任何其他 App 长按粘贴
- **浏览器 tab**：WebView 模式。内嵌 SwiftUI WebView（iOS 26 `WebPage`）+ 预设书签（Claude / ChatGPT / 豆包 / Kimi / DeepSeek / 通义）。ASR 文字直接通过 `WebPage.callJavaScript` 注入到当前焦点的 `<input>` / `<textarea>` / `[contenteditable]`，使用最长公共前缀 diff 做增量编辑。同时仍写剪贴板兜底
- **设置 tab**：豆包凭证 + 书签管理

浏览器 tab 工具栏：返回 / 前进 / 模式徽章 / 粘贴剪贴板 / **键盘 toggle**。键盘 toggle 默认抑制软键盘——焦点进入输入框时不会自动弹出 iOS 软键盘（适合搭配 ASR / 蓝牙键盘使用），点一下按钮可以手动唤起；再点一下收起。底层走 `inputmode="none"` 标准 HTML 属性热切换，不依赖任何私有 API。

iOS 限制说明：
- 系统不允许 inter-app 键盘注入，所以 macOS 版的"自动打字到任意 App"在 iOS 端做不到。WebView 模式是这个能力在 iOS 上的最近替代——仅在 App 内嵌的网页有效
- 凭证存储用 `UserDefaults`（后续会迁到 Keychain）
- 后台保活通过 Info.plist 的 `bluetooth-central` background mode；切到其他 App 粘贴时 GATT 不掉
- Gemini 暂不支持（Google OAuth 拒绝在 WKWebView/WebView 中登录）

首次启动：
1. 系统弹**蓝牙权限** → 允许
2. 切到"设置"tab → 填入豆包 App ID / Access Token / Resource ID → 保存
3. 切到"浏览器"tab → 选 Claude（或其他书签）→ 登录一次 → 输入框点一下获得焦点 →（如需键盘点工具栏键盘按钮）→ 按住设备 A 按钮说话

### 端到端验证流程

1. 给 StickS3 上电，屏幕显示 `VibeBuddy-XXXX` + 黄色 `advertising`，右上角电量条
2. 启动 VibeBuddy macOS App，几秒内屏幕转绿色 `link: 2M mtu=517`
3. 在 Mac 上打开 **TextEdit** → 新建空白文档 → 保持焦点
4. 按住设备 A 按钮说中文 5–10 秒
5. VibeBuddy 窗口里能看到蓝色 partial 文字实时滚动，TextEdit 同步出字
6. 松开 A → 1 秒内文字稳定为黑色 final 结果

## 单元测试

```bash
make test           # 共享 SwiftPM 测试 + iOS App 测试
make test-shared    # 只跑 VibeBuddyCore（Gzip / Config / AudioStreamer / STTService）
make test-ios       # 只跑 iOS App 端（TextRouter / PasteboardHandler / TextDiff /
                    #                  InjectionScript / BookmarkStore 等）
```

测试不依赖真硬件。SwiftUI WebView 的 JS 注入（包含焦点跟踪、increment diff、键盘抑制）需要在真机或模拟器上手动验证。

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
make fw-monitor
```

关键标签：`[boot]` / `[ble]` / `[link]` / `[rec]` / `[mic]` / `[tick]` / `[rec-tick]`

### macOS 日志

```bash
log stream --predicate 'process == "VibeBuddy"' --style compact
```

关键标签：`[ble]` / `[json]` / `[audio]` / `[stt]`

### iOS 日志

iOS 端关键标签：`[ble]` / `[stt]` / `[wv]`（WebView 注入）。模拟器在 Xcode console 直接看；真机用 Console.app 按进程名 `VibeBuddy` 过滤。

## BLE 协议要点

完整规范不再单独维护文档，源码即文档。几个关键不变量：

- **BLE 服务**：复用 Nordic UART Service（NUS），UUID `6E400001-...`，与 [claude-desktop-buddy](https://github.com/imliubo/claude-desktop-buddy/tree/feat/migrate-to-m5unified) 协议兼容
- **广播名**：`VibeBuddy-XXXX`（XXXX = BT MAC 后 4 位十六进制）
- **帧分派**：JSON 文本帧以 `\n` 结束；音频二进制帧以魔数 `0xFF 0xAA` 起头，后跟 `seq[2B LE]` + `len[2B LE]` + PCM
- **链路协商**：连接建立后固件请求 2M PHY + MTU 517（notify payload 上限 500 B）+ DLE 251 + conn interval 7.5–15ms，结果通过 `{"type":"link","phy":"...","mtu":...}` 上报
- **采样率**：固定 16 kHz，无降级档。2M PHY 是硬性前提——协商不到 2M 时 `recorderStart()` 直接拒绝录音而不是降级，让问题暴露而不是藏起来（见 `ble_bridge.h` 顶部注释）。仍通过 `{"type":"audio","event":"start","sample_rate":N}` 告知 Mac
- **录音上限**：60 秒硬切（`recorder.cpp` `MAX_RECORD_MS`），防按键卡住烧豆包时长费；触发时走正常 stop 流程，已说的话照常转写

## 关键设计决策

几处踩坑经验：

- StickS3 的扬声器与麦克风共享 ES8311，用 `cfg.internal_spk = false` 释放 I2S
- M5Unified 的 `M5.Mic.record()` 异步 API 用单缓冲会产生 chunk 重复 → 用 ping-pong
- BLE 默认 LL PDU 27 字节会把 500 B notify 拆 20 段，必须显式调 `esp_ble_gap_set_prefered_default_phy` + `esp_ble_gap_set_pkt_data_len(251)`
- iOS 默认 connection interval 可能给 30ms，主动 `esp_ble_gap_update_conn_params` 请求 7.5–15ms
- 豆包协议每帧都带 4 字节 seq（文档里没写清），最后一帧用**负数** seq + flag `0x3`
- 豆包鉴权 header 名是 `X-Api-Request-Id`（不是文档里的 `X-Api-Connect-Id`）
- iOS WebView 抑制软键盘的正确姿势是 `inputmode="none"` 标准 HTML 属性，对已聚焦元素改属性会热切换键盘——不要去 swizzle `inputAccessoryView`，也不要走 `blur()`/`focus()` 因为程序化 focus 拿不到 user gesture，键盘不会弹

## 路线图

Phase 1（已完成）：按住录音 → 流式 ASR → 增量注入，端到端走通；iOS 浏览器 tab + 三 tab 架构；固件电量进度条；iOS 26 SwiftUI WebView 迁移；浏览器键盘抑制 toggle。

Phase 2（计划中）：
- Claude 权限申请的硬件审批流
- 文字编辑辅助模式（双击换行、BtnB backspace）
- BLE 加密配对
- 屏幕菜单与设置页
- iOS Keychain 凭证管理

## 许可

待定。
