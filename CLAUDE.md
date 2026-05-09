# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目一句话

按住 PTT 录音 → 流式 ASR（豆包）→ 文字注入到目标输入框。音频源有两种：M5Stack StickS3（BLE）或本机麦克风。文字落点有三种：macOS CGEvent 全局注入、iOS 应用内剪贴板、iOS 内嵌 SwiftUI WebView 的 JS 增量注入。

## 常用命令

`Makefile` 是唯一入口，敲 `make` 看菜单。最常用的：

```bash
make gen          # 改了 *-app/project.yml 之后必须重跑（xcodegen → xcodeproj）
make build        # 同时编 macos + ios（Debug）
make test         # SwiftPM + iOS 模拟器全部单测
make test-shared  # 只跑 VibeBuddyCore（最快的反馈环）
make fw-upload    # 编固件并烧到 StickS3
make fw-monitor   # 串口日志（115200，标签：[boot] [ble] [link] [rec] [mic] [tick]）
make open         # 打开 VibeBuddy.xcworkspace
```

注意 `xcodeproj` 是 gitignored 的，`make build-*` 已经依赖 `gen-*`，但手工 `xcodebuild` 之前要先 `make gen`。

跑单个 SwiftPM 测试：

```bash
cd shared && swift test --filter VibeBuddyCoreTests.AudioStreamerTests/testChunkBoundary
```

跑单个 iOS 测试（XCTest 命名 `Target/Class/Method`）：

```bash
cd ios-app && xcodebuild -project VibeBuddy-iOS.xcodeproj -scheme VibeBuddy-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:VibeBuddyTests/TextRouterTests/testRoutesToWebViewWhenAvailable test | xcbeautify
```

## 架构骨架

三个端共用一个核心 SPM 包：

```
firmware/ (C++/PlatformIO)        shared/Sources/VibeBuddyCore (Swift Package)         macos-app/ + ios-app/
─────────────────────────         ──────────────────────────────────────────         ──────────────────────
StickS3 → BLE NUS notify  ──┐                                                          ┌── macOS: TextInjector (CGEvent)
                            │     PTTTrigger ──► PTTSession ──► AudioStreamer          │
本机麦克风 (AVFoundation) ──┼──► (按键事件)     (会话状态机)   (200ms chunk)  ──► STTService ──► AppState ──► TextHandler
                            │                                  └► MicCaptureController                       │
                            │                                                                                ├── iOS 转写 tab: PasteboardHandler
                            └──► BLEController (CoreBluetooth Central)                                       └── iOS 浏览器 tab: WebViewInjector (JS diff)
```

### `shared/Sources/VibeBuddyCore` 是单一事实源

任何业务逻辑改动都先在这里写，两端 App 只接 UI / 平台特定胶水。关键文件：

- **`PTTTrigger.swift`**：协议，把"按下/松开"事件抽象掉。两个具体实现分别在 `macos-app/HotKeyPTTTrigger.swift`（全局热键）和 `ios-app/ButtonPTTTrigger.swift`（屏幕按键）。
- **`PTTSession.swift`**：会话状态机，串起 trigger → 音源 → STT。所有"按下时启 / 松开时停"的协调点都在这里。
- **`MicCaptureController.swift`**：本机麦克风采集（AVAudioEngine）。**生命周期必须严格绑到 PTT 事件**——按下才 start，松开就 stop & 释放——否则系统状态栏麦克风指示灯会一直亮。两端 App 通过 `AudioSourceCoordinator.swift` 在 BLE 音源 / 本机麦音源之间切换。
- **`BLEController.swift`**：CoreBluetooth Central，按 NUS 协议跑帧分派。文本帧 `\n` 结束、二进制帧魔数 `0xFF 0xAA` 起头（详见 README "BLE 协议要点"）。
- **`AudioStreamer.swift`**：把零碎 PCM 切成 200ms chunk，喂给 STTService。
- **`STTService.swift`**：豆包流式 ASR 的二进制协议 + WebSocket。鉴权 header 是 `X-Api-Request-Id`（不是文档里的 `X-Api-Connect-Id`），最后一帧用**负数** seq + flag `0x3`。
- **`AppState.swift`**：`@MainActor ObservableObject`，UI 绑这个。
- **`TextHandler.swift`**：跨平台文字落点协议；macOS 实现是 `TextInjector`（CGEvent），iOS 实现是 `TextRouter`（在 `PasteboardHandler` ↔ `WebViewInjector` 间路由）。
- **`Config.swift`**：凭证读取。macOS 走 XDG (`~/.config/vibe-buddy/config.json`)，iOS 走 `UserDefaults`。

### iOS WebView 注入（`ios-app/VibeBuddy/WebView/`）

iOS 26 SwiftUI 原生 `WebPage` API（不是 `WKWebView` + `UIViewRepresentable`），所以**最低 iOS 26**。注入路径：

`STTService` 出 partial → `AppState` → `TextRouter` 选浏览器 tab → `WebViewInjector` 通过 `WebPage.callJavaScript` 把 `InjectionScript.swift` 里的 JS 函数喂入参 → JS 端用最长公共前缀 diff 增量改 `<input>/<textarea>/[contenteditable]`。

键盘抑制走 `inputmode="none"` 标准属性热切换——**不要** swizzle `inputAccessoryView`，**不要**用 `blur()`/`focus()`（程序化 focus 拿不到 user gesture，键盘弹不出来）。

### macOS 全局注入（`macos-app/VibeBuddy/TextInjector.swift`）

CGEvent + 最长公共前缀 diff，按 partial 增量打字。`FocusGate.swift` + `FrontAppMonitor.swift` 处理"只在某些 App 注入"的逻辑，`InputMonitoringPermission.swift` 管 Accessibility 授权弹窗。

## 关键约束 / 易踩坑

- **xcodeproj 是 gitignored 的**，签名相关只放 `*-app/Local.xcconfig`（`DEVELOPMENT_TEAM` 等），改完 `project.yml` 必须 `make gen`。
- **iOS 26 / iPadOS 26** 是硬下限（SwiftUI WebView）。要支持更低版本得整体回退到 WKWebView。
- **macOS 14 (Sonoma)** 是下限（CoreBluetooth + Accessibility 行为）。
- 麦克风 / BLE 音源切换之后，旧音源必须停干净——任何"start 了没 stop"的路径都会导致系统麦指示灯常亮、电量异常或 GATT 通道占用。审改 `MicCaptureController` / `AudioSourceCoordinator` / `PTTSession` 时第一反射就是检查"释放对称"。
- 固件侧 BLE 协商参数（2M PHY、MTU 247、DLE 251、conn interval 7.5–15ms）是端到端 <1s 延迟的前提，详细 trade-off 在 README "BLE 协议要点" + "关键设计决策"。
- 提交规范看用户全局 CLAUDE.md（Conventional Commits，scope 用域名，描述中文，不要 Co-Author / Claude Code 字样，**不要主动 commit/push**）。

## 调试工具

- **纯 BLE 验证（不走豆包）**：`tools/ble_audio_dump.py`（bleak 客户端）抓 PCM 落盘，绕开 App + ASR。详见 README "调试工具"。
- **macOS 日志**：`log stream --predicate 'process == "VibeBuddy"' --style compact`，关键标签 `[ble] [json] [audio] [stt]`。
- **iOS 日志**：模拟器在 Xcode console 看，真机用 Console.app 按 `VibeBuddy` 过滤。关键标签 `[ble] [stt] [wv]`。
- **固件日志**：`make fw-monitor`，标签 `[boot] [ble] [link] [rec] [mic] [tick] [rec-tick]`。

## 端到端验证

按 README "端到端验证流程" 走：上电 StickS3 → 启 macOS App 看到绿色 `link: 2M mtu=517` → TextEdit 焦点 → 按住 A 说话 → 看到蓝色 partial 实时滚动，松手 1 秒内变黑色 final。
