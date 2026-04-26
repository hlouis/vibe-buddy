import Foundation

// JavaScript payloads that run inside the WKWebView to apply diff-based
// text edits on whatever element currently has focus. We keep all the
// JS as Swift string constants here so the actual injection logic is
// reviewable in one place — Swift only computes (deleteCount,
// insertText) and ships the strings across.
//
// The "vbApply" helper handles three element flavors with a graceful
// fallback chain:
//
//   1. <input> / <textarea>  — uses the native value setter so React /
//      Vue / Svelte rebroadcast the change as if the user typed it.
//   2. contenteditable        — uses execCommand('delete'/'insertText'),
//      which still works in WebKit and notifies most rich editors that
//      front-load on input events.
//   3. anything else          — returns ok=false so the Swift layer can
//      surface "no injectable focus" to the UI.
//
// Document-start script that posts focus changes back to native lives
// here too, so the status bar can show "focus: textarea#prompt" before
// the user even speaks.
enum InjectionScript {

    // Installed via WKUserScript on every page load. Posts the current
    // focus descriptor to the "vbFocus" message handler whenever a
    // focusin / focusout event bubbles up. Tagged forMainFrameOnly:false
    // so chat sites that nest editors in iframes still notify us when
    // focus is in their main content area.
    static let focusTracker: String = #"""
    (function() {
        function descriptor(el) {
            if (!el || el === document.body) return null;
            const tag = el.tagName || '';
            const id = el.id ? '#' + el.id : '';
            const cls = (typeof el.className === 'string' && el.className)
                ? '.' + el.className.split(/\s+/).filter(Boolean).slice(0, 2).join('.')
                : '';
            const editable = el.isContentEditable ? '[ce]' : '';
            const injectable = (tag === 'INPUT' || tag === 'TEXTAREA' || el.isContentEditable);
            return { focus: tag + id + cls + editable, injectable: injectable };
        }
        function post(el) {
            const d = descriptor(el);
            try {
                window.webkit.messageHandlers.vbFocus.postMessage(d || { focus: '', injectable: false });
            } catch (e) {}
        }
        document.addEventListener('focusin', function(e) { post(e.target); }, true);
        document.addEventListener('focusout', function() { post(null); }, true);
        // Fire once at install time so the initial state is visible too.
        post(document.activeElement);
    })();
    """#

    // Apply a diff to the focused element. deleteCount characters are
    // removed before the caret, then insertText is inserted. Returns a
    // JSON-string result via evaluateJavaScript's completion handler.
    static func applyDiff(deleteCount: Int, insertText: String) -> String {
        let escapedInsert = jsString(insertText)
        return #"""
        (function(deleteCount, insertText) {
            function focused() {
                let el = document.activeElement;
                while (el && el.shadowRoot && el.shadowRoot.activeElement) {
                    el = el.shadowRoot.activeElement;
                }
                return el;
            }
            const el = focused();
            if (!el || el === document.body) {
                return JSON.stringify({ ok: false, reason: 'no-focus' });
            }
            const tag = el.tagName;
            const tagDesc = tag + (el.id ? '#' + el.id : '');
            try {
                if (tag === 'INPUT' || tag === 'TEXTAREA') {
                    const proto = (tag === 'INPUT')
                        ? HTMLInputElement.prototype
                        : HTMLTextAreaElement.prototype;
                    const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                    const cur = el.value || '';
                    const caret = (typeof el.selectionStart === 'number')
                        ? el.selectionStart : cur.length;
                    const cutEnd = Math.max(0, caret - deleteCount);
                    const newVal = cur.slice(0, cutEnd) + insertText + cur.slice(caret);
                    setter.call(el, newVal);
                    const newCaret = cutEnd + insertText.length;
                    try { el.setSelectionRange(newCaret, newCaret); } catch (e) {}
                    el.dispatchEvent(new InputEvent('input', {
                        bubbles: true, inputType: 'insertText', data: insertText
                    }));
                    return JSON.stringify({ ok: true, mode: 'value-setter', focus: tagDesc });
                }
                if (el.isContentEditable) {
                    el.focus();
                    for (let i = 0; i < deleteCount; i++) {
                        document.execCommand('delete', false);
                    }
                    if (insertText && insertText.length > 0) {
                        document.execCommand('insertText', false, insertText);
                    }
                    return JSON.stringify({ ok: true, mode: 'execCommand', focus: tagDesc });
                }
                return JSON.stringify({ ok: false, reason: 'unsupported', focus: tagDesc });
            } catch (e) {
                return JSON.stringify({ ok: false, reason: 'exception', error: String(e) });
            }
        })(\#(deleteCount), \#(escapedInsert));
        """#
    }

    // Hardware "clear all" button — wipe the entire focused field, not
    // just our mirror. Preserves the existing macOS semantics.
    static let clearAll: String = #"""
    (function() {
        function focused() {
            let el = document.activeElement;
            while (el && el.shadowRoot && el.shadowRoot.activeElement) {
                el = el.shadowRoot.activeElement;
            }
            return el;
        }
        const el = focused();
        if (!el || el === document.body) {
            return JSON.stringify({ ok: false, reason: 'no-focus' });
        }
        const tag = el.tagName;
        try {
            if (tag === 'INPUT' || tag === 'TEXTAREA') {
                const proto = (tag === 'INPUT')
                    ? HTMLInputElement.prototype
                    : HTMLTextAreaElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                setter.call(el, '');
                el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContent' }));
                return JSON.stringify({ ok: true, mode: 'value-setter' });
            }
            if (el.isContentEditable) {
                el.focus();
                document.execCommand('selectAll', false);
                document.execCommand('delete', false);
                return JSON.stringify({ ok: true, mode: 'execCommand' });
            }
            return JSON.stringify({ ok: false, reason: 'unsupported' });
        } catch (e) {
            return JSON.stringify({ ok: false, reason: 'exception', error: String(e) });
        }
    })();
    """#

    // MARK: helpers

    // JS string literal escaping. Wraps in double quotes and escapes
    // backslash, double-quote, newline, carriage return, paragraph and
    // line separators (the two unicode ones break JS literals). Plain
    // JSONSerialization is overkill for a single string and produces
    // identical output for ASCII / BMP text.
    private static func jsString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{2028}": out.append("\\u2028")
            case "\u{2029}": out.append("\\u2029")
            default:
                if ch.value < 0x20 {
                    out.append(String(format: "\\u%04x", ch.value))
                } else {
                    out.append(Character(ch))
                }
            }
        }
        out.append("\"")
        return out
    }
}
