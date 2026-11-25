# 硬件调试流程

## 为什么需要这个文档

2026-07-17，设备端 Opus 那次改动：编译通过、81 个单测全绿、`make test-ogg` 用真 ffmpeg 解码也通过。烧进真机，**一按录音键必崩**。

崩的原因是 `opus_encode()` 撑爆了 Arduino `loopTask` 的 8 KB 默认栈。所有主机侧的检查都够不着这条路径——它们全在 Mac 上跑。

更糟的是它的伪装。从 App 日志看到的是：

```
[json] {"type":"audio","event":"start","sample_rate":16000,"codec":"opus"}
[audio] STT warmup elapsed — arming session, flushing 0 pre-buffered bytes
[stt] ws handshake OK
[ble] disconnected: The connection has timed out unexpectedly.     ← 4.07 秒后
```

读起来像「BLE 链路超时」，会让人去查连接参数。**实际是设备崩溃重启了**：崩溃时不会发 disconnect PDU，所以 Mac 只能等满 supervision timeout（我们设的 4 秒）才发现对端没了。

**主机侧的每一个绿灯，都只证明主机侧没问题。**

---

## 三层验证，各自的盲区

| 层 | 命令 | 能抓到 | **抓不到** |
|---|---|---|---|
| 单元测试 | `make test-shared` | 我们自己写下的断言 | 我们**错误的假设**——Ogg EOS 页曾经多写一个零长 lacing segment，单测断言的正是这个 bug，全绿 |
| 真解码器 | `make test-ogg` | 真 ffmpeg 拒收的字节流 | 任何设备上发生的事 |
| 真机 | 见下 | 崩溃、时序、栈、功耗 | — |

每一层只能验证它够得着的东西。**跳过任何一层，它的盲区就是你的 bug。**

---

## 环境陷阱（都踩过）

### `pio device monitor` 不能后台跑

需要 TTY，重定向就抛 `Console()` traceback。而硬件调试最需要的恰恰是「挂着录，我去按按钮，回来再读」。

用 `make fw-capture`（`tools/fw_capture.py`）代替。

### 系统 python3 没有 pyserial

PlatformIO 的解释器有：

```bash
/opt/homebrew/opt/platformio/libexec/bin/python
```

`make fw-capture` 已经帮你解析好了。

### `log` 是 zsh 内建命令

zsh 有个 csh 兼容遗留的 `log` builtin，会把参数吃掉：

```bash
log stream --predicate '...'      # (eval):log:3: too many arguments
/usr/bin/log stream --predicate '...'   # 对
```

### App 的 NSLog 进不了 unified log

`/usr/bin/log stream --predicate 'process == "VibeBuddy"'` 能看到系统框架的日志，但**看不到我们的 `[ble]` / `[audio]` / `[stt]`**。别在这上面浪费时间。

### 直接跑二进制 = 蓝牙被拒

```bash
.../VibeBuddy.app/Contents/MacOS/VibeBuddy    # ✗
```

这样跑，TCC 会把权限归属到**父终端**上。如果终端没有蓝牙权限，`CBCentralManager` 永远不 poweredOn，一条 `[ble] scanning` 都没有——程序活着，只是蓝牙被挡。

查谁有权限：

```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "select client, auth_value from access where service='kTCCServiceBluetoothAlways'"
# auth_value: 0=拒绝 2=允许
```

### 正确姿势：`open --stderr`

保留 App 自己的 TCC 归属，同时拿到 stderr：

```bash
open --stdout /tmp/vb.txt --stderr /tmp/vb.txt \
  "$(ls -d ~/Library/Developer/Xcode/DerivedData/VibeBuddy-macOS-*/Build/Products/Debug/VibeBuddy.app)"
```

不用改任何系统权限。

### 插着 USB 却没有串口（设备睡着时插的线）

USB 枚举由 USB Serial/JTAG 硬件完成，light sleep 时它停摆。熄屏睡眠中插线，
主机的复位没人应答，主机放弃后不再重试——`/dev/cu.usbmodem*` 不出现，
`make fw-upload` 一直等。固件在检测到 VBUS 后会拉低 D+ 一下逼主机重新枚举
（`main.cpp` 的 `usbReenumerate()`），正常应在 10 s 内出现串口。没出现时：
按一下按键亮屏，再拔插一次。

---

## 标准流程：同时抓两侧

崩溃诊断**必须**两侧对齐时间戳，只看一侧会被伪装骗到。

```bash
# 1. 串口后台持续录
make fw-capture &

# 2. App 带 stderr 重定向启动
pkill -x VibeBuddy; sleep 1
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/VibeBuddy-macOS-*/Build/Products/Debug/VibeBuddy.app)
open --stdout /tmp/vb.txt --stderr /tmp/vb.txt "$APP"

# 3. 按按钮

# 4. 读，去掉 2 行/秒的噪音底
grep -vE '^\[pwr\]|^\[tick\]|^\[mic\] chunk' /tmp/vibebuddy-serial.txt | tail -40
grep -vE '"type":"log"|"type":"hb"' /tmp/vb.txt | grep -E '\[audio\]|\[stt\]|\[ble\]' | tail -20
```

抓启动日志（`[boot]` / 崩溃 backtrace 只在复位时出现）：

```bash
make fw-capture ARGS="--reset --seconds 10 --echo"
```

---

## 崩溃诊断

### 症状伪装对照表

| 主机侧看到的 | 真实原因 | 怎么确认 |
|---|---|---|
| `[ble] disconnected: The connection has timed out unexpectedly.`，距会话开始正好 ~4 秒 | **设备崩溃重启**（崩溃不发 disconnect PDU，主机只能等 supervision timeout） | 串口找 `Backtrace` / `rst:0x` |
| `bytes=0` / `flushing 0 pre-buffered bytes` | 设备一个音频包都没发出来 | 串口看 `[rec] start` 之后有没有 `[rec] stopped` |
| 链路显示 `? PHY · MTU 20` | 刚重连、还没协商完 | 设备是不是刚重启 |
| 音频中途卡住但链路不断 | 主循环被卡（`recorderTick` 无界循环之类）。BLE 协议栈在 core 0、`loop()` 在 core 1，所以链路还在，只是帧和心跳都停了 | 串口 `[tick]` 停止递增，约 5 秒后出现 `task_wdt` 报 `IDLE (CPU 1)`（只告警不复位） |

### 判断设备是否重启过：看 `[tick]`

`[tick]` 每秒 +1，从 boot 开始。**烧录十几分钟后 tick 却只有个位数/十几 = 刚崩过。**

今天就是这一行先把方向掰回来的——在此之前所有证据都指向 BLE。

```bash
grep -c "boot\] Vibe Buddy" /tmp/vibebuddy-serial.txt   # 本次会话重启了几次
grep -E "overflow|Guru|Backtrace|rst:0x" /tmp/vibebuddy-serial.txt
```

### 栈溢出长这样

```
***ERROR*** A stack overflow in task loopTask has been detected.
Backtrace: 0x40378202:0x3fce7970 ... |<-CORRUPTED
Rebooting...
rst:0xc (RTC_SW_CPU_RST)
```

`loopTask` 默认栈 8 KB。任何在 `loop()` 里调用的重型库（libopus 就是）都可能捅穿。现在由 `sdkconfig.defaults` 的 `CONFIG_ARDUINO_LOOP_STACK_SIZE=32768` 设定——**不是** `SET_LOOP_TASK_STACK_SIZE`，那个宏靠覆盖预编译核心的弱符号生效，而 espidf-component 构建从源码编译 Arduino 核心，宏是 no-op。

---

## 不走豆包的纯 BLE 验证

要把「链路/编码」和「ASR/网络」分开定位时用：

```bash
python3 -m venv tools/.venv && tools/.venv/bin/pip install bleak
tools/.venv/bin/python tools/ble_audio_dump.py
# 按住 A 录一段，松开：
afplay out.ogg
```

脚本按固件声明的 codec 自动走 Ogg 或 PCM。**注意**：bleak 的蓝牙权限归属到你的终端 App，需要在 系统设置 → 隐私与安全性 → 蓝牙 里放行（见上面的 TCC 查询）。

---

## 日志标签速查

| 端 | 标签 | 含义 |
|---|---|---|
| 固件 | `[boot]` | 启动。出现 = 重启过 |
| | `[rec]` | 录音会话。`start` / `stopped: frames=.. enc=..us` |
| | `[btn]` | 按键。屏幕全黑时首次按下只唤醒屏幕（`aWakeOnly`），要按第二次才录音 |
| | `[tick]` | 1 Hz 心跳，**判断重启的关键** |
| | `[pm]` | 电源锁的获取/释放、启动时的 PM 配置、USB 插入重枚举 |
| | `[pwr]` | 1 Hz：电压、mV/min、背光、`pmcpu`/`pmawake` 锁状态、`slp`/`wk` 实测睡眠（同一行也经 BLE 发到 App） |
| App | `[ble]` | 扫描 / 连接 / 断开 |
| | `[audio]` | 会话、trim、gap |
| | `[stt]` | 豆包 WebSocket、partial、FINAL |
| | `[json]` | 设备发来的原始控制帧 |

---

## 一次健康的会话长什么样

```
固件: [btn] A pressed -> start record (speculative)
      [rec] start @ 16000 Hz opus
      [btn] A released after 5924ms -> stop record
      [rec] stopped: frames=98 bytes=14700 overruns=0 enc=19446us/60000us
App:  [json] {"type":"audio","event":"start","sample_rate":16000,"codec":"opus"}
      [audio] session -> .../out.ogg (codec=opus rate=16000 tailTrim=200ms warmup=400ms)
      [audio] STT warmup elapsed — arming session, flushing N pre-buffered bytes
      [stt] FINAL seq=96 text=...
      [audio] session done: bytes=14100 gaps=0 trim_tail=4 dur=5.93s
```

要盯的数字：

- **`gaps=0`** — 丢帧。非 0 说明链路或 drain 跟不上
- **`overruns=0`** — ring 溢出。非 0 说明 `recorderTick` 排空速度不够
- **`trim_tail=4`** — 应当恒为 4 包（240 ms），即松手咔哒声被吃掉
- **`enc=…us/60000us`** — 编码耗时 vs 实时预算。见下

---

## 已实测的硬约束

**Opus 编码：一帧 60 ms 音频要 19–22 ms**（240 MHz，complexity 1）= 实时预算的三分之一。当初估的是 2–5 ms，**差了 5 倍**。

会随内容波动（静音比说话便宜），**按高值算**。实测两次：`enc=19446us`（98 帧）、`enc=21968us`（71 帧）。

由此两条依赖是硬的，破了就会「编码慢于实时」：

1. **录音全程必须锁 240 MHz。** `main.cpp` 的 `cpuLock` 在录音时持有，目前成立。但 80 MHz 下同样一帧要 ~66 ms，**直接超出 60 ms 预算**。
2. **`OPUS_SET_COMPLEXITY` 不能往上调。**

`recorder.cpp` 的 `MAX_ENCODES_PER_TICK = 4` 是最后一道闸：没有它，编码一旦慢于实时，`while (ringAvail() >= 960)` 永远为真 → `loop()` 永不返回 → 音频帧和心跳全停。不会崩溃重启，串口只有 `task_wdt` 告警。

改动 codec 参数或调频策略后，回来看 `enc=` 这个数。

---

## 功耗测量：几乎每种「显而易见」的方法都会骗你

排查「空转发热」时，下面每一条都实际发生过，都浪费了时间。

### mV/min 斜率分辨不了空闲功耗

`[pwr]` 遥测的电压斜率是 AXP2101 没有电流 ADC 逼出来的代理量，但它的噪声
是结构性的：相邻 1 秒采样能摆动 **64 mV**（一块 200mAh 电池在恒定负载下
物理上不可能），4 分钟窗口的信噪比只有 **0.36**。而且 60 秒滑动窗口让相邻
样本共享 59/60 的数据——240 个样本的有效独立样本数约为 **4**。

3 分钟分段能读出 `+4.0 mV/min`（放电中电压上涨）。看到这种数就该停手。

**要用它，只能用小时级窗口，且必须比较「相同电压区间的耗时」**——锂电曲线
在 4.1→3.9 陡、3.9→3.7 平，用固定时长比较会被曲线形状骗。

### 电量百分比不是电量

StickS3 **没有电量计**，M5Unified 是拿电压线性插值（3300mV=0%，4100mV=100%）。
刚拔充电线时表面电荷消散，电压瞬间回落几十 mV——**看起来像掉电，其实一点
电都没少**。实测：拔线瞬间 77% → 69%。

「10 分钟从 95% 掉到 52%」里有相当一部分是这个效应，不是放电。

### `getCpuFrequencyMhz()` 在任务里永远返回 max

esp_pm 给每个核建了一把内部 `CPU_FREQ_MAX` 锁（`pm_impl.c` 里的
`rtos0`/`rtos1`），**只要该核有任务可跑就持有**。所以任何在任务里调用
`getCpuFrequencyMhz()` 的代码，都是在「持有该锁的上下文」里读频率——
**永远读到 240，无论 DFS 是否在工作**。

任务侧代码在结构上无法观测空闲频率，日志里因此不报 CPU 频率。

### 睡没睡着：看 `[pwr]` 的 `slp=` / `wk=`

锁全部释放（`pmcpu=0 pmawake=0`）只说明**允许**睡；tickless idle 在下一次
唤醒不足 3 ms 时仍会跳过。真正睡了多少由 `main.cpp` 的
`__wrap_esp_light_sleep_start` 实测（`platformio.ini` 的
`--wrap=esp_light_sleep_start`）：`slp` = 上一秒实际 light sleep 占比，
`wk` = 进入次数。这两个数随 BLE 日志到达主机，拔线后也能看。

`wk` 是找唤醒源的线索。熄屏空闲的健康值是个位数每秒（主循环约 1 次，
按键靠中断唤醒；BLE 靠 peripheral latency 跳过空闲连接事件），`slp` 在
85–90%。≈67/s 说明每个 15 ms 连接事件都在醒（latency 没生效）；≈20/s
说明主循环退回了 50 ms 轮询（`idleWait()` 没走到，或有按键被判为按住）。

### 手指仍是最终判据

发热是功耗的直接物理证据。`slp` 说明 CPU 睡了多少，但不覆盖屏幕面板、
codec、晶振这些外设。拿它当二分法信号：改一个东西 → 拔线 → 静置 10 分钟 → 摸。

### 占空比可以精确测量，而且够用

背光/CPU 状态是数字量，遥测报的就是真值。`front_app` 唤醒那个 bug 就是
这么定量的：**55.7% 的时间全亮满频 → 0%**。

**测得准的东西测占空比，测不准的东西别测。**
