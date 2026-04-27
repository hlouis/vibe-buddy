import Foundation

// JavaScript payloads that run inside the SwiftUI WebView (iOS 26+
// WebPage / callJavaScript) to apply diff-based text edits on whatever
// element currently has focus. We keep all the JS as Swift string
// constants here so the actual injection logic is reviewable in one
// place.
//
// Calling convention: WebPage.callJavaScript(_:arguments:) treats the
// Swift string as a JavaScript *function body* and the Swift dictionary
// as named arguments injected directly into the function's local scope.
// We never interpolate user-supplied text into JS source any more — the
// system marshals each argument as a real JS value, which kills the
// entire string-escaping (and string-injection-attack) surface that the
// old WKWebView+evaluateJavaScript path required.
//
// Each function body must `return` a plain JS object; WebKit bridges it
// back to Swift as `[String: Any]?`, so the native side reads it as a
// dictionary directly — no JSON parsing.
//
// The "vbApply" payload handles three element flavors with a graceful
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
// Document-end script that posts focus changes back to native is
// installed via WKUserScript on the configuration's userContentController.
enum InjectionScript {

    // Document-end user script. Posts the current focus descriptor to
    // the "vbFocus" message handler whenever a focusin / focusout event
    // bubbles up. Tagged forMainFrameOnly:false so chat sites that nest
    // editors in iframes still notify us when focus is in their main
    // content area. Unchanged from the WKWebView era: WKUserScript +
    // WKScriptMessageHandler still exist on WebPage.Configuration.
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

    // Function body for callJavaScript. Receives `deleteCount` (Int) and
    // `insertText` (String) as named arguments — already type-safe JS
    // values, no escaping needed. Returns a plain JS object that WebKit
    // bridges back to the Swift caller as [String: Any].
    static let applyDiff: String = #"""
    function focused() {
        let el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) {
            el = el.shadowRoot.activeElement;
        }
        return el;
    }
    const el = focused();
    if (!el || el === document.body) {
        return { ok: false, reason: 'no-focus' };
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
            return { ok: true, mode: 'value-setter', focus: tagDesc };
        }
        if (el.isContentEditable) {
            el.focus();
            for (let i = 0; i < deleteCount; i++) {
                document.execCommand('delete', false);
            }
            if (insertText && insertText.length > 0) {
                document.execCommand('insertText', false, insertText);
            }
            return { ok: true, mode: 'execCommand', focus: tagDesc };
        }
        return { ok: false, reason: 'unsupported', focus: tagDesc };
    } catch (e) {
        return { ok: false, reason: 'exception', error: String(e) };
    }
    """#

    // Document-end user script that suppresses iOS's auto-popup keyboard
    // by stamping `inputmode="none"` on text fields as they receive
    // focus. The toolbar's keyboard toggle flips `window.__vbKbSuppressed`
    // — when false, this script restores each field's original inputmode
    // on focus instead. Per WebKit, mutating inputmode on the already-
    // focused element hot-swaps the on-screen keyboard, which is what
    // makes the toggle feel instant without any blur/focus dance (which
    // wouldn't work anyway — programmatic focus() doesn't satisfy the
    // user-gesture gate for showing the keyboard).
    static let keyboardSuppressor: String = #"""
    (function() {
        if (window.__vbKbInstalled) return;
        window.__vbKbInstalled = true;
        window.__vbKbSuppressed = true;

        function isTextInput(el) {
            if (!el) return false;
            const tag = el.tagName;
            return tag === 'INPUT' || tag === 'TEXTAREA' || el.isContentEditable;
        }
        function suppress(el) {
            if (!isTextInput(el)) return;
            if (!el.hasAttribute('data-vb-orig-im')) {
                el.setAttribute('data-vb-orig-im', el.getAttribute('inputmode') || '');
            }
            el.setAttribute('inputmode', 'none');
        }
        function restore(el) {
            if (!isTextInput(el)) return;
            const orig = el.getAttribute('data-vb-orig-im');
            if (orig === null) return;
            if (orig) el.setAttribute('inputmode', orig);
            else el.removeAttribute('inputmode');
            el.removeAttribute('data-vb-orig-im');
        }
        document.addEventListener('focusin', function(e) {
            if (window.__vbKbSuppressed) suppress(e.target);
            else restore(e.target);
        }, true);
        if (document.activeElement && window.__vbKbSuppressed) {
            suppress(document.activeElement);
        }
    })();
    """#

    // Function body for callJavaScript. Receives `suppressed: Bool` and
    // applies the new state both to the global flag (for future focusin
    // events handled by keyboardSuppressor) and to whatever is focused
    // right now. Mutating inputmode on the focused element is what makes
    // the keyboard appear/disappear without needing a user-gesture-gated
    // focus() call.
    static let setKeyboardSuppressed: String = #"""
    function focused() {
        let el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) {
            el = el.shadowRoot.activeElement;
        }
        return el;
    }
    window.__vbKbSuppressed = !!suppressed;
    const el = focused();
    if (!el || el === document.body) {
        return { ok: true, focus: '' };
    }
    const tag = el.tagName;
    const isInput = (tag === 'INPUT' || tag === 'TEXTAREA' || el.isContentEditable);
    if (!isInput) {
        return { ok: true, focus: '' };
    }
    if (suppressed) {
        if (!el.hasAttribute('data-vb-orig-im')) {
            el.setAttribute('data-vb-orig-im', el.getAttribute('inputmode') || '');
        }
        el.setAttribute('inputmode', 'none');
    } else {
        const orig = el.getAttribute('data-vb-orig-im');
        if (orig !== null) {
            if (orig) el.setAttribute('inputmode', orig);
            else el.removeAttribute('inputmode');
            el.removeAttribute('data-vb-orig-im');
        }
    }
    return { ok: true, focus: tag };
    """#

    // Hardware "clear all" button — wipe the entire focused field, not
    // just our mirror. No arguments needed.
    static let clearAll: String = #"""
    function focused() {
        let el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) {
            el = el.shadowRoot.activeElement;
        }
        return el;
    }
    const el = focused();
    if (!el || el === document.body) {
        return { ok: false, reason: 'no-focus' };
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
            return { ok: true, mode: 'value-setter' };
        }
        if (el.isContentEditable) {
            el.focus();
            document.execCommand('selectAll', false);
            document.execCommand('delete', false);
            return { ok: true, mode: 'execCommand' };
        }
        return { ok: false, reason: 'unsupported' };
    } catch (e) {
        return { ok: false, reason: 'exception', error: String(e) };
    }
    """#
}
