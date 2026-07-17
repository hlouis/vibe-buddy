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

    // BtnA short-press dispatch. Receives a `mode` plus a flat bag of
    // mode-specific arguments (see SiteKeyPolicy.dispatchArguments).
    // Four branches, matching the four KeyAction cases:
    //
    //   • mode === 'insertText'  — write the given string at the caret
    //     using the value-setter / execCommand fallback. Bypasses
    //     isTrusted; the only path that reliably "types" into a
    //     vanilla <textarea>.
    //   • mode === 'keyEvent'    — synthesize a keydown/keyup pair on
    //     the focused element. isTrusted is false (synthesized events
    //     can't be trusted by design); React-based UIs that only
    //     inspect e.key / e.shiftKey react, sites that gate on
    //     isTrusted silently swallow it.
    //   • mode === 'beforeInput' — dispatch a single 'beforeinput'
    //     InputEvent with the requested inputType. ProseMirror / Slate
    //     editors that ignore synthetic KeyboardEvents typically still
    //     honour this path.
    //   • mode === 'click'       — querySelector + .click() on a
    //     site-specific target element. Doesn't require a focused
    //     input, so this branch runs *before* the focus guard.
    //
    // All arguments are referenced unconditionally; the Swift side
    // sends a fully-populated dict so no branch hits a ReferenceError.
    static let dispatchKeyAction: String = #"""
    function focused() {
        let el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) {
            el = el.shadowRoot.activeElement;
        }
        return el;
    }
    // Click is selector-driven, not focus-driven — handle it before
    // the focus guard so it works even when nothing is focused.
    if (mode === 'click') {
        const target = document.querySelector(selector);
        if (!target) {
            return { ok: false, reason: 'no-target', selector: selector };
        }
        try {
            target.click();
            const targetDesc = target.tagName + (target.id ? '#' + target.id : '');
            return { ok: true, mode: 'click', focus: targetDesc };
        } catch (e) {
            return { ok: false, reason: 'exception', error: String(e) };
        }
    }
    const el = focused();
    if (!el || el === document.body) {
        return { ok: false, reason: 'no-focus' };
    }
    const tag = el.tagName;
    const tagDesc = tag + (el.id ? '#' + el.id : '');
    try {
        if (mode === 'insertText') {
            if (tag === 'INPUT' || tag === 'TEXTAREA') {
                const proto = (tag === 'INPUT')
                    ? HTMLInputElement.prototype
                    : HTMLTextAreaElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                const cur = el.value || '';
                const caret = (typeof el.selectionStart === 'number')
                    ? el.selectionStart : cur.length;
                const newVal = cur.slice(0, caret) + insertText + cur.slice(caret);
                setter.call(el, newVal);
                const newCaret = caret + insertText.length;
                try { el.setSelectionRange(newCaret, newCaret); } catch (e) {}
                el.dispatchEvent(new InputEvent('input', {
                    bubbles: true, inputType: 'insertText', data: insertText
                }));
                return { ok: true, mode: 'insertText', focus: tagDesc };
            }
            if (el.isContentEditable) {
                el.focus();
                document.execCommand('insertText', false, insertText);
                return { ok: true, mode: 'insertText', focus: tagDesc };
            }
            return { ok: false, reason: 'unsupported', focus: tagDesc };
        }
        if (mode === 'keyEvent') {
            const init = {
                key: key,
                code: code || key,
                keyCode: keyCode || 0,
                which: keyCode || 0,
                shiftKey: !!shiftKey,
                ctrlKey:  !!ctrlKey,
                altKey:   !!altKey,
                metaKey:  !!metaKey,
                bubbles: true,
                cancelable: true,
            };
            const defaulted = el.dispatchEvent(new KeyboardEvent('keydown', init));
            el.dispatchEvent(new KeyboardEvent('keyup', init));
            return { ok: true, mode: 'keyEvent', defaulted: defaulted, focus: tagDesc };
        }
        if (mode === 'beforeInput') {
            const ev = new InputEvent('beforeinput', {
                bubbles: true,
                cancelable: true,
                inputType: inputType || 'insertLineBreak',
                data: data || null,
            });
            el.dispatchEvent(ev);
            return { ok: true, mode: 'beforeInput', focus: tagDesc };
        }
        return { ok: false, reason: 'unknown-mode', focus: tagDesc };
    } catch (e) {
        return { ok: false, reason: 'exception', error: String(e) };
    }
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

    // Document-start user script that intercepts blob:/data: downloads
    // so native code can save them. Must be document-start so we patch
    // HTMLAnchorElement.prototype.click *before* any page script grabs
    // a reference to the original.
    //
    // Two-layer interception (one is not enough):
    //
    //   1. Monkey-patch HTMLAnchorElement.prototype.click. Catches the
    //      "create <a>, set href to blob:, call .click()" pattern even
    //      when the <a> is detached from the DOM — and that *is* the
    //      common pattern (FileSaver.js, SheetJS, ExcelJS all do this
    //      with no appendChild). A document-level click listener can't
    //      see those because detached-element events don't propagate up.
    //   2. document.addEventListener('click', ..., true) as a fallback
    //      for the actually-in-the-DOM case (user clicks a real
    //      <a download href=blob:>).
    //
    // Patterns this does NOT catch (acceptable v1 limitations):
    //   • window.open(blobUrl)
    //   • window.location.href = blobUrl
    //   • cross-origin iframe-internal triggers
    //
    // Native side wires this to a WKScriptMessageHandler named
    // "vbDownload" — see BlobDownloadBridge in BrowserState.swift.
    static let blobDownloadHook: String = #"""
    (function() {
        if (window.__vbBlobHookInstalled) return;
        window.__vbBlobHookInstalled = true;

        // 50MB cap. base64 over the WebKit ↔ App IPC bridge balloons
        // memory roughly 3-4x (JS string + base64 inflation + native
        // copy on the receive side), and anything bigger risks an OOM
        // before we even hit save. SPAs producing Excel rarely break
        // single-digit MB, so this leaves plenty of headroom.
        const MAX_BYTES = 50 * 1024 * 1024;

        function post(msg) {
            try {
                window.webkit.messageHandlers.vbDownload.postMessage(msg);
            } catch (e) {
                // Native handler missing — shouldn't happen in this app,
                // but better to no-op than throw and break the page.
            }
        }

        async function handle(href, filename) {
            try {
                const res = await fetch(href);
                const blob = await res.blob();
                if (blob.size > MAX_BYTES) {
                    post({
                        error: '文件超过 50MB 上限',
                        filename: filename,
                        size: blob.size,
                    });
                    return;
                }
                const reader = new FileReader();
                reader.onerror = () => post({
                    error: 'FileReader 失败',
                    filename: filename,
                });
                reader.onload = () => post({
                    dataUrl: reader.result,
                    filename: filename,
                    mime: blob.type || 'application/octet-stream',
                    size: blob.size,
                });
                reader.readAsDataURL(blob);
            } catch (err) {
                post({ error: String(err), filename: filename });
            }
        }

        function isHandledHref(href) {
            return typeof href === 'string'
                && (href.startsWith('blob:') || href.startsWith('data:'));
        }

        // Layer 1: HTMLAnchorElement.prototype.click monkey-patch.
        // Captures detached-<a>.click() — the dominant SPA pattern.
        const origClick = HTMLAnchorElement.prototype.click;
        HTMLAnchorElement.prototype.click = function() {
            try {
                if (this.hasAttribute('download') && isHandledHref(this.href)) {
                    const name = this.getAttribute('download') || 'download';
                    handle(this.href, name);
                    return; // swallow — iOS WebKit can't save blobs natively anyway
                }
            } catch (e) { /* fall through to original */ }
            return origClick.apply(this, arguments);
        };

        // Layer 2: capture-phase document click listener.
        // Catches user-initiated clicks on attached <a download>.
        document.addEventListener('click', function(e) {
            const a = e.target && e.target.closest && e.target.closest('a[download]');
            if (!a) return;
            if (!isHandledHref(a.href)) return;
            e.preventDefault();
            e.stopPropagation();
            const name = a.getAttribute('download') || 'download';
            handle(a.href, name);
        }, true);
    })();
    """#
}
