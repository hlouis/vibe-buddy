#!/usr/bin/env swift
//
// ax_probe — does AXUIElementSetAttributeValue actually stick?
//
// Background: TextInjector types via CGEvent, whose only primitive against a
// field we don't own is "backspace from the cursor". That makes replacing an
// already-typed string O(n) keyboard events (~4ms each). If AX can set the
// value atomically instead, a post-hoc LLM polish pass becomes free.
//
// FocusGate already calls AXUIElementIsAttributeSettable(kAXValue) and treats
// the answer as a boolean gate. This probe asks the next question: when it
// says yes, does the set land? Electron/web hosts are the suspects — hence
// read-back verification rather than trusting the AXError.
//
// Usage:  swift tools/ax_probe.swift [--delay N] [--detach]
//
//   --delay N   seconds to click into the target field (default 5)
//   --detach    after the in-place tests, wait for you to switch to another
//               app, then set the *saved* element again. Tests whether AX
//               targets the element (survives focus change) or the focus.
//
// The terminal running this needs Accessibility:
//   System Settings → Privacy & Security → Accessibility → enable your terminal.
// TCC attributes the permission to the terminal app, not to swift(1).

import Foundation
import ApplicationServices
import AppKit

// MARK: - args

var delaySec: UInt32 = 5
var testDetach = false
var force = false
var argv = Array(CommandLine.arguments.dropFirst())
while let a = argv.first {
    argv.removeFirst()
    switch a {
    case "--delay":
        if let v = argv.first, let n = UInt32(v) { delaySec = n; argv.removeFirst() }
    case "--detach":
        testDetach = true
    case "--force":
        force = true
    case "-h", "--help":
        print("usage: swift tools/ax_probe.swift [--delay N] [--detach] [--force]")
        exit(0)
    default:
        FileHandle.standardError.write("unknown arg: \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

// MARK: - AX helpers

// Returns the focused element plus the AXError, so callers can tell "no AX at
// all" (apiDisabled) apart from "app exposes nothing focused" (noValue).
func focusedElement(of parent: AXUIElement) -> (AXUIElement?, AXError) {
    var raw: AnyObject?
    let err = AXUIElementCopyAttributeValue(parent, kAXFocusedUIElementAttribute as CFString, &raw)
    guard err == .success, let any = raw, CFGetTypeID(any) == AXUIElementGetTypeID()
    else { return (nil, err) }
    return ((any as! AXUIElement), err)
}

func attrString(_ el: AXUIElement, _ attr: String) -> String? {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success else { return nil }
    return raw as? String
}

func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
    var s: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(el, attr as CFString, &s) == .success else { return false }
    return s.boolValue
}

@discardableResult
func setString(_ el: AXUIElement, _ attr: String, _ v: String) -> AXError {
    AXUIElementSetAttributeValue(el, attr as CFString, v as CFTypeRef)
}

func selectedRange(_ el: AXUIElement) -> CFRange? {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
          let any = raw, CFGetTypeID(any) == AXValueGetTypeID()
    else { return nil }
    var r = CFRange()
    guard AXValueGetValue((any as! AXValue), .cfRange, &r) else { return nil }
    return r
}

@discardableResult
func setSelectedRange(_ el: AXUIElement, _ r: CFRange) -> AXError {
    var rr = r
    guard let v = AXValueCreate(.cfRange, &rr) else { return .failure }
    return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
}

func errName(_ e: AXError) -> String {
    switch e {
    case .success:                    return "success"
    case .attributeUnsupported:       return "attributeUnsupported"
    case .actionUnsupported:          return "actionUnsupported"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .illegalArgument:            return "illegalArgument"
    case .invalidUIElement:           return "invalidUIElement"
    case .cannotComplete:             return "cannotComplete"
    case .notImplemented:             return "notImplemented"
    case .noValue:                    return "noValue"
    case .apiDisabled:                return "apiDisabled"
    case .failure:                    return "failure"
    default:                          return "AXError(\(e.rawValue))"
    }
}

func brief(_ s: String?, _ n: Int = 48) -> String {
    guard let s else { return "<nil>" }
    let one = s.replacingOccurrences(of: "\n", with: "⏎")
    return one.count <= n ? "\"\(one)\"" : "\"\(String(one.prefix(n)))…\"(\(one.count))"
}

// MARK: - permission

guard AXIsProcessTrusted() else {
    print("""
    ✗ 没有 Accessibility 权限。

      系统设置 → 隐私与安全性 → 辅助功能 → 勾选你的终端 App
      （TCC 把权限归属到终端，不是 swift 本身）

      勾上之后可能要重启终端。
    """)
    exit(1)
}

// MARK: - capture

print("→ \(delaySec) 秒内点进目标 App 的输入框（随便打几个字，非空更能暴露问题）")
for i in stride(from: Int(delaySec), to: 0, by: -1) {
    print("  \(i)…", terminator: "")
    fflush(stdout)
    sleep(1)
}
print()

let front = NSWorkspace.shared.frontmostApplication
let frontApp = front?.localizedName ?? "?"
let frontPid = front?.processIdentifier ?? 0
print("  frontmost: \(frontApp) (pid \(frontPid))")

// Two routes to the same element. The systemwide one is what FocusGate uses;
// the app-scoped one often answers when systemwide returns noValue.
let (sysEl, sysErr) = focusedElement(of: AXUIElementCreateSystemWide())
print("  systemwide kAXFocusedUIElement : \(errName(sysErr))")

var appErr: AXError = .noValue
var appEl: AXUIElement? = nil
if frontPid > 0 {
    (appEl, appErr) = focusedElement(of: AXUIElementCreateApplication(frontPid))
    print("  app-scoped  kAXFocusedUIElement : \(errName(appErr))")
}

guard let el = sysEl ?? appEl else {
    print("""

    ✗ 两条路都拿不到 focused element。

      trusted=\(AXIsProcessTrusted())  systemwide=\(errName(sysErr))  app-scoped=\(errName(appErr))

      • apiDisabled     → 终端没有 Accessibility 权限（勾了也要重启终端）
      • noValue         → 焦点不在文本控件上，或该 App 压根不暴露 AX
      • cannotComplete  → 目标 App 主线程卡住 / 没响应 AX 请求
      • frontmost 是你的终端 → 倒计时内没切走，重跑并加 --delay 8
    """)
    exit(1)
}
let role = attrString(el, kAXRoleAttribute as String) ?? "?"
let subrole = attrString(el, kAXSubroleAttribute as String) ?? "-"
let original = attrString(el, kAXValueAttribute as String)

print("""

  app     : \(frontApp)
  role    : \(role)  subrole=\(subrole)
  value   : \(brief(original))
""")

// Everything below mutates the field. Put it back no matter how we exit.
// Two paths on purpose: a field can be settable via kAXSelectedText but not
// via kAXValue (the Electron case this probe exists to find), and then the
// kAXValue path silently leaves our marker behind.
func restore() {
    guard let original else { return }
    setString(el, kAXValueAttribute as String, original)
    usleep(80_000)
    if attrString(el, kAXValueAttribute as String) == original { return }

    let cur = attrString(el, kAXValueAttribute as String) ?? ""
    setSelectedRange(el, CFRange(location: 0, length: (cur as NSString).length))
    usleep(60_000)
    setString(el, kAXSelectedTextAttribute as String, original)
    usleep(80_000)
    if attrString(el, kAXValueAttribute as String) != original {
        print("  ⚠️  没能还原原内容 —— 手动 Cmd+Z 一下")
    }
}

// MARK: - test 0: does this app honor AX writes at all?
//
// Setting a selection range moves the caret but never touches text, so this is
// safe against a live chat input. Electron hosts (Feishu) accept the write,
// return .success, and quietly drop it — the range read-back is the only
// signal that separates them from a field that actually obeys. Gates the
// destructive tests below, because on those apps a bad write is unrecoverable:
// restore() is itself an AX write and gets swallowed the same way.

print("\n── TEST 0: 选区写入（非破坏性，判别器）──")
let probeLen = original.map { ($0 as NSString).length } ?? 0
if probeLen == 0 {
    print("  ⚠️  字段是空的 —— 选区 0,0 永远读回 0,0，区分不出任何东西。")
    print("      在框里打几个字再重跑。")
}
let t0Take = min(4, probeLen)
let t0Target = CFRange(location: probeLen - t0Take, length: t0Take)
let t0Err = setSelectedRange(el, t0Target)
usleep(80_000)
let t0Landed = selectedRange(el)
let t0OK = probeLen > 0
    && (t0Landed.map { $0.location == t0Target.location && $0.length == t0Target.length } ?? false)
print("  set range \(t0Target.location),\(t0Target.length)      : \(errName(t0Err))")
print("  range read-back     : \(t0Landed.map { "\($0.location),\($0.length)" } ?? "<读不回来>")")
print("  → \(t0OK ? "✓ 这个 App 老实执行 AX 写入" : "✗ 写入被无声吞掉")")

if !t0OK && !force {
    print("""

    ────────────────────────────────────────────────
      \(frontApp)  [role=\(role)]
        0  选区写入（判别器）        ✗  → AX 这条路在这个 App 上不可用
    ────────────────────────────────────────────────

      已跳过 TEST A/B。这个 App 的 AX 写入不可信，跑下去只会把你的
      输入框搞脏、而且还原不回来（飞书就是这么脏的）。

      判别器为真时才有资格写 —— 这正是产品代码要做的事。
      非要强跑：make ax-probe ARGS="--force"
    """)
    exit(0)
}

// MARK: - test A: set kAXValue wholesale

print("\n── TEST A: set kAXValue ──")
let aSettable = isSettable(el, kAXValueAttribute as String)
print("  IsAttributeSettable : \(aSettable)")

let markerA = (original ?? "") + "【A】"
let aErr = setString(el, kAXValueAttribute as String, markerA)
usleep(120_000)
let aReadBack = attrString(el, kAXValueAttribute as String)
let aStuck = (aReadBack == markerA)
print("  SetAttributeValue   : \(errName(aErr))")
print("  read-back           : \(brief(aReadBack))")
print("  → \(aStuck ? "✓ 生效" : "✗ 没生效")")
restore()
usleep(120_000)

// MARK: - test B: replace a sub-range via kAXSelectedText
//
// This is the shape we actually want: swap only the span we injected and
// leave the user's pre-existing content alone.

print("\n── TEST B: kAXSelectedTextRange + kAXSelectedText ──")
let rangeSettable = isSettable(el, kAXSelectedTextRangeAttribute as String)
let selSettable = isSettable(el, kAXSelectedTextAttribute as String)
print("  range settable      : \(rangeSettable)")
print("  selectedText settable: \(selSettable)")

let baseline = attrString(el, kAXValueAttribute as String) ?? ""
let nsLen = (baseline as NSString).length
let takeLen = min(4, nsLen)
let target = CFRange(location: nsLen - takeLen, length: takeLen)

let rErr = setSelectedRange(el, target)
usleep(80_000)

// Read the selection back before writing through it. Safari's address bar
// mutates asynchronously (autocomplete), which desyncs the range we computed
// from the text actually in the field — without this check a moving field
// looks identical to an unsettable one.
let landedRange = selectedRange(el)
let rangeOK = landedRange.map { $0.location == target.location && $0.length == target.length } ?? false
let drifted = attrString(el, kAXValueAttribute as String) ?? ""
let fieldMoved = (drifted != baseline)

print("  set range \(target.location),\(target.length)      : \(errName(rErr))")
if let lr = landedRange {
    print("  range read-back     : \(lr.location),\(lr.length) \(rangeOK ? "✓" : "✗ 选区没落在要求的位置")")
} else {
    print("  range read-back     : <读不回来>")
}
if fieldMoved {
    print("  ⚠️  字段在我们操作期间自己变了: \(brief(baseline)) → \(brief(drifted))")
    print("      （自动补全类控件——B 的结果不可信，换个普通输入框测）")
}

let sErr = setString(el, kAXSelectedTextAttribute as String, "【B】")
usleep(120_000)
let bReadBack = attrString(el, kAXValueAttribute as String)
let expectedB = (drifted as NSString).length >= target.location + target.length
    ? (drifted as NSString).replacingCharacters(
        in: NSRange(location: target.location, length: target.length), with: "【B】")
    : "<字段长度已变，无法预测>"
let bStuck = (bReadBack == expectedB)
print("  set selectedText    : \(errName(sErr))")
print("  read-back           : \(brief(bReadBack))")
print("  expected            : \(brief(expectedB))")
print("  → \(bStuck ? "✓ 生效" : (fieldMoved ? "? 不可信（字段在动）" : "✗ 没生效"))")
restore()
usleep(120_000)

// MARK: - test C: does the saved element outlive focus?
//
// The claim being tested: AX targets an element, CGEvent targets whatever has
// focus. If true, a delayed polish patch can't land in the wrong app.

var cStuck: Bool? = nil
if testDetach {
    print("\n── TEST C: detached set（切走之后还能不能打回原来那个框）──")
    print("→ 5 秒内切到别的 App / 点进别的输入框")
    for i in stride(from: 5, to: 0, by: -1) {
        print("  \(i)…", terminator: "")
        fflush(stdout)
        sleep(1)
    }
    print()
    let nowFront = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    let markerC = (original ?? "") + "【C】"
    let cErr = setString(el, kAXValueAttribute as String, markerC)
    usleep(120_000)
    let cReadBack = attrString(el, kAXValueAttribute as String)
    cStuck = (cReadBack == markerC)
    print("  frontmost now       : \(nowFront)")
    print("  SetAttributeValue   : \(errName(cErr))")
    print("  read-back           : \(brief(cReadBack))")
    print("  → \(cStuck! ? "✓ 打回去了（元素引用存活）" : "✗ 没打回去")")
    restore()
}

// MARK: - verdict

func mark(_ b: Bool) -> String { b ? "✓" : "✗" }
print("""

────────────────────────────────────────────────
  \(frontApp)  [role=\(role)]
    0  选区写入（判别器）        \(mark(t0OK))
    A  kAXValue 整体替换        \(mark(aStuck))   (settable 声称: \(aSettable))
    B  kAXSelectedText 换段落   \(fieldMoved ? "?  字段自己在动，重测" : mark(bStuck))
\(testDetach ? "    C  切走后仍能打回          \(mark(cStuck ?? false))\n" : "")────────────────────────────────────────────────

  注意：read-back ✓ 只证明 AX 层收下了。Electron/React 这类
  自己维护状态的框，可能 AX 读回是新值但 App 自身没感知（发送时
  丢失、或下一次重绘被打回）。眼睛看一下那个框，并且如果能发送就
  发一条试试。
""")
