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
├── tools/
│   ├── ble_audio_dump.py           # 纯 BLE 端到端验证脚本（bleak 客户端）
│   ├── fw_capture.py               # 可后台的串口录制（fw-monitor 需要 TTY，用不了）
│   └── verify_ogg_mux.py           # 真 Opus 包 → 我们的 muxer → ffmpeg 解码
└── docs/
    └── hardware-debug.md           # 硬件调试流程 / 崩溃诊断 / 症状伪装对照表
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
make test           # 共享 SwiftPM 测试 + Ogg 封装验证 + iOS App 测试
make test-shared    # 只跑 VibeBuddyCore（Gzip / Config / AudioStreamer / OggOpusMuxer / …）
make test-ogg       # 真 Opus 包 → 我们的 muxer → ffmpeg 解码（需要 ffmpeg）
make test-ios       # 只跑 iOS App 端（TextRouter / PasteboardHandler / TextDiff /
                    #                  InjectionScript / BookmarkStore 等）
```

**以上全部跑在主机上，一项都碰不到设备。** 单测只能验证我们自己写下的断言——Ogg EOS 页那个 bug 就是单测断言了错误假设还全绿，靠 `make test-ogg` 的真解码器才抓到；而 `opus_encode` 撑爆固件栈那个，三层主机检查全绿，只有真机能抓到。

固件改动 **必须** 走真机验证，流程见 [docs/hardware-debug.md](docs/hardware-debug.md)。SwiftUI WebView 的 JS 注入（焦点跟踪、increment diff、键盘抑制）同样需要真机或模拟器手动验证。

## 调试工具

完整的硬件调试流程、崩溃诊断、以及「主机侧症状 → 真实原因」对照表见 **[docs/hardware-debug.md](docs/hardware-debug.md)**。下面是速查。

### 纯 BLE 验证（不走豆包）

用 Python 脚本直接抓 BLE 音频流落盘，绕开 Mac App 和 ASR：

```bash
python3 -m venv tools/.venv
tools/.venv/bin/pip install bleak
tools/.venv/bin/python tools/ble_audio_dump.py
# 按住 A 录一段，松开后（固件现在发 Opus，脚本自动封成 Ogg）：
afplay out.ogg
```

脚本按固件在 `audio/start` 里声明的 `codec` 走：`opus` → 封 Ogg 落 `out.ogg`（直接可播）；无 `codec` 字段（Opus 之前的旧固件）→ 裸 PCM 落 `out.pcm`。

脚本里的 Ogg muxer 是 `OggOpusMuxer.swift` 的逐行移植——**改一个必须改另一个**，否则这个工具会「证明」App 里并不存在的 bug。`make test-ogg` 就是拿真 Opus 包过一遍我们的 muxer 再让 ffmpeg 解码，验证两边都没跑偏。

### 固件日志

```bash
make fw-monitor                              # 交互式盯屏
make fw-capture &                            # 后台录到 /tmp/vibebuddy-serial.txt
make fw-capture ARGS="--reset --seconds 10"  # 复位后录，抓 [boot] / 崩溃 backtrace
```

`make fw-monitor` 需要 TTY，后台跑或重定向会直接抛 traceback——要挂着录就用 `fw-capture`。

关键标签：`[boot]` / `[ble]` / `[link]` / `[rec]` / `[mic]` / `[tick]` / `[pwr]`

**`[tick]` 是判断设备有没有崩过的关键**：它每秒 +1，从 boot 起算。烧录十几分钟后 tick 却只有十几 = 刚重启过。

### macOS 日志

```bash
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/VibeBuddy-macOS-*/Build/Products/Debug/VibeBuddy.app)
open --stdout /tmp/vb.txt --stderr /tmp/vb.txt "$APP"
```

关键标签：`[ble]` / `[json]` / `[audio]` / `[stt]`

两个坑，都会浪费你半小时：

- **`log stream --predicate 'process == "VibeBuddy"'` 看不到我们的 NSLog**，只有系统框架的日志。别试了
- **不要直接跑 `VibeBuddy.app/Contents/MacOS/VibeBuddy`**：TCC 会把蓝牙权限归属到父终端，终端没授权的话 `CBCentralManager` 永远不 poweredOn，程序活着但一条 `[ble]` 都没有。`open --stderr` 保留 App 自己的 TCC 归属，不用改任何系统设置

### iOS 日志

iOS 端关键标签：`[ble]` / `[stt]` / `[wv]`（WebView 注入）。模拟器在 Xcode console 直接看；真机用 Console.app 按进程名 `VibeBuddy` 过滤。

## BLE 协议要点

完整规范不再单独维护文档，源码即文档。几个关键不变量：

- **BLE 服务**：复用 Nordic UART Service（NUS），UUID `6E400001-...`，与 [claude-desktop-buddy](https://github.com/imliubo/claude-desktop-buddy/tree/feat/migrate-to-m5unified) 协议兼容
- **广播名**：`VibeBuddy-XXXX`（XXXX = BT MAC 后 4 位十六进制）
- **设备配对**：应用层白名单，不是 BLE bonding（链路仍是明文，加密见 Phase 2）。白名单存 `XXXX` 后缀——它源自 BT MAC，跨主机稳定，跟机身屏幕上显示的一致。macOS 存 `~/.config/vibe-buddy/devices.json`，iOS 存 `UserDefaults`。**白名单为空 = 连第一个搜索到的设备**（保持老行为，升级不会断连）；非空则只连白名单内的。配对界面在 macOS `设置 → 设备` / iOS `设置 → 蓝牙设备`
- **帧分派**：JSON 文本帧以 `\n` 结束；音频二进制帧以魔数 `0xFF 0xAA` 起头，后跟 `seq[2B LE]` + `len[2B LE]` + payload
- **音频编码**：设备端 Opus（CBR 20kbps，60ms/帧 = 960 样本，VOIP 模式，complexity 1，DTX 关）。一帧 = 一个 Opus 包 = 一个 notify，约 150B + 6B 头，**~2.8 KB/s**（裸 PCM 是 32 KB/s）。主机**全程不解码**：`OggOpusMuxer` 封成 Ogg 直接喂豆包（`format:ogg, codec:opus`）。编解码器在 `{"type":"audio","event":"start",...,"codec":"opus"}` 里声明；**字段缺失 = PCM**，所以旧固件配新 App 仍然能用
- **链路协商**：连接建立后固件请求 2M PHY + MTU 517（notify payload 上限 500 B）+ DLE 251 + conn interval 7.5–15ms。协商结果随 **1Hz 心跳**上报：`{"type":"hb","seq":N,"btn_a":bool,"phy":"2M","mtu":517}`。**不用一次性通知**——曾经有个 `{"type":"link"}` 帧在 PHY 就绪时立刻发一次，但那时 CoreBluetooth 还没走完 `setNotifyValue()`，notify 被静默丢弃且无重传，约 50% 的概率让 UI 永远卡在 `? PHY / MTU 20`。值得持续显示的事实不该用「发完即忘」的消息传递
- **采样率**：固定 16 kHz，无降级档。通过 `{"type":"audio","event":"start","sample_rate":N,"codec":"opus"}` 告知 Mac
- **2M PHY 是优化，不是要求**：每次连接都请求 2M（空中时间减半，免费），但拿不到就用 1M——Opus 只要 ~20 kbps，1M 绰绰有余。裸 PCM 时代 2M 是硬性前提（拿不到就拒绝录音），Opus 之后那个硬性要求只剩下「在不支持 2M 的主机上把设备变砖」这一个作用，已去掉。**现在真正制约录音的是 MTU**：一帧 Opus 必须装进一个 notify，所以 `recorderStart()` 检查 `MTU ≥ 159`（6 字节头 + 150 字节 CBR 包 + 3 字节 ATT 开销），不够就拒绝并在屏幕上标红
- **录音上限**：60 秒硬切（`recorder.cpp` `MAX_RECORD_MS`），防按键卡住烧豆包时长费；触发时走正常 stop 流程，已说的话照常转写

## 关键设计决策

### 设备端 Opus，主机永不解码

音频在 StickS3 上就编成 Opus（CBR 20 kbps / 60 ms 帧），主机只负责封 Ogg 转发给豆包。**BLE 上的音频从 32 KB/s 降到 ~2.5 KB/s，实测 12 倍。**

为什么主机不解码：muxing 是纯字节拼装，decoding 不是。不解码 = `shared/` 不需要引 libopus（目前是纯 Swift + Foundation），iOS/macOS 都不用打包原生依赖。

代价是**管道分叉**：麦克风音源仍是 PCM，所以 `AudioStreamer` 按 session codec 分流——Opus 按整包 trim（60 ms 粒度，200 ms 窗口向上取整成 4 包），PCM 按字节 trim 再切 200 ms chunk。两条路在 `emitToSinks` 汇合，warmup 门控完全共用。这是权衡后接受的：另一条路（主机解码回 PCM，单管道）要在两个平台上引入 libopus。

向后兼容：`codec` 是 `audio/start` JSON 的**新增字段，缺失即 PCM**，所以旧固件配新 App 照常工作。

**硬约束（实测，别破）**：一帧 60 ms 音频编码要 **19–22 ms**（240 MHz / complexity 1），占实时预算三分之一，且随内容波动。因此录音全程必须锁 240 MHz（`main.cpp` 的 DFS 按 `recorderActive()` 拉满，80 MHz 下要 ~66 ms 直接超预算），且 complexity 不能上调。破了会让编码慢于实时，`recorder.cpp` 的 `MAX_ENCODES_PER_TICK = 4` 是最后一道闸。细节见 [docs/hardware-debug.md](docs/hardware-debug.md)。

### 几处踩坑经验

- `loopTask` 默认栈只有 8 KB，`opus_encode()` 直接捅穿 → `SET_LOOP_TASK_STACK_SIZE(32 * 1024)`。**这个崩溃从主机侧看是「BLE 4 秒超时断连」**，因为设备崩溃时不发 disconnect PDU
- Ogg EOS 页必须声明**零个** lacing segment，不是「一个长度为 0 的 segment」——后者等于声明一个零字节包，Opus 里不存在，ffmpeg 拒收整个流。单测断言过这个 bug 且全绿，是 `make test-ogg` 抓到的
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
