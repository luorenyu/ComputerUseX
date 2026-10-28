import Foundation
import AppKit
import CoreGraphics

public final class KeyboardController: @unchecked Sendable {
    public static let shared = KeyboardController()

    private static let keyCodeTable: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53,
        "f17": 64, "clear": 71,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103,
        "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111, "f15": 113,
        "help": 114, "home": 115, "pageup": 116, "forwarddelete": 117, "f4": 118,
        "end": 119, "f2": 120, "pagedown": 121, "f1": 122,
        "left": 123, "arrowleft": 123,
        "right": 124, "arrowright": 124,
        "down": 125, "arrowdown": 125,
        "up": 126, "arrowup": 126
    ]

    private init() {}

    /// Parses a shortcut combo like `"cmd+shift+p"`, `"ctrl+c"`, `"enter"`, `"opt+space"`
    public static func parseShortcut(_ combo: String) throws -> (flags: CGEventFlags, keyCode: CGKeyCode) {
        let parts = combo
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else {
            throw OCUError(
                code: .invalidArguments,
                message: "Empty key shortcut specification.",
                recoveryHint: "Pass a key or shortcut like 'enter', 'cmd+c', 'cmd+shift+p'."
            )
        }

        var flags = CGEventFlags()
        var targetKey: String? = nil

        for part in parts {
            switch part {
            case "cmd", "command", "meta", "super":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "opt", "option", "alt":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            case "fn":
                flags.insert(.maskSecondaryFn)
            default:
                targetKey = part
            }
        }

        guard let keyName = targetKey, let code = keyCodeTable[keyName] else {
            throw OCUError(
                code: .invalidArguments,
                message: "Unrecognized key '\(targetKey ?? combo)' in shortcut '\(combo)'.",
                recoveryHint: "Use standard key names like 'a'-'z', '0'-'9', 'enter', 'tab', 'space', 'escape', 'up', 'down', 'left', 'right'."
            )
        }

        return (flags, code)
    }

    public func pressShortcut(_ combo: String, virtualCursor: Bool? = nil) throws -> ActionOutcome {
        let startTime = Date()
        let isVirtual = virtualCursor ?? MouseController.shared.useVirtualCursorByDefault
        if isVirtual {
            try KillSwitchMonitor.shared.verifySafeToProceed()
        } else {
            try KillSwitchMonitor.shared.verifySafeToProceed()
        }
        let (flags, keyCode) = try Self.parseShortcut(combo)

        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "⌨️ 按键 \(combo)", subtitle: nil)
        )

        let targetPid = resolveTargetPid(forVirtualMode: isVirtual)
        if flags == .maskCommand && keyCode == 0, let pid = targetPid, pid > 0 {
            AXScanner.shared.selectAllInFocusedElement(pid: pid)
        }
        postKeyCode(keyCode, flags: flags, targetPid: targetPid)
        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
        KillSwitchMonitor.shared.logAction("⌨️ Pressed \(combo)")
        return ActionOutcome(
            action: "press",
            targetDescription: combo,
            elapsedMs: ms
        )
    }

    public func typeText(
        _ text: String,
        target: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        dx: Double? = nil,
        dy: Double? = nil,
        clearFirst: Bool = false,
        submit: Bool = false,
        imagePath: String? = nil,
        virtualCursor: Bool? = nil
    ) throws -> ActionOutcome {
        let startTime = Date()
        let isVirtual = virtualCursor ?? MouseController.shared.useVirtualCursorByDefault
        if isVirtual {
            try KillSwitchMonitor.shared.verifySafeToProceed()
        } else {
            try KillSwitchMonitor.shared.verifySafeToProceed()
        }

        let userFrontmostApp = NSWorkspace.shared.frontmostApplication
        let offsetX = dx ?? 0
        let offsetY = dy ?? 0
        let hasOffset = (abs(offsetX) > 0.1 || abs(offsetY) > 0.1)
        let hasNewlines = text.contains("\n") || text.contains("\r")
        let hasImageAttachment = (imagePath != nil && !imagePath!.isEmpty)

        let restoreUserFocusIfNeeded: (Int32?) -> Void = { pid in
            guard isVirtual,
                  let userApp = userFrontmostApp,
                  let tPid = pid,
                  userApp.processIdentifier != tPid else {
                return
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == tPid {
                userApp.activate()
            }
        }

        // Fast Path A: When targeting an AX text field in virtual mode with no relative offset, try setting
        // kAXValueAttribute / kAXSelectedTextAttribute directly so background browsers/Cocoa/Electron apps
        // receive text (including multiline text) without stealing OS focus, switching Spaces, or touching clipboard.
        // Skip Fast Path A only when text starts with "@" (mention popup trigger) or includes an image attachment.
        var attemptedNativeAXForTarget = false
        if isVirtual && !hasOffset && !text.hasPrefix("@") && !hasImageAttachment && !text.isEmpty,
           let targetRef = target, !targetRef.isEmpty,
           let el = try? ElementSnapshotStore.shared.resolveTarget(targetRef),
           el.source == .ax {
            let winCtx = SyntheticFocusEnforcer.shared.resolveTargetWindow(
                at: el.centerPoint,
                preferredPid: el.pid,
                preferredAppName: el.appName
            )
            if AXScanner.shared.resolveLiveAXElement(for: el.ref, pid: el.pid) != nil {
                attemptedNativeAXForTarget = true
                try MouseController.shared.moveSmoothly(
                    to: el.centerPoint,
                    duration: 0.16,
                    virtualCursor: true,
                    windowID: winCtx?.windowID,
                    pid: el.pid,
                    label: nil
                )
                Thread.sleep(forTimeInterval: 0.05)
                var nativeSetOk = AXScanner.shared.performNativeSetValue(
                    ref: el.ref,
                    value: text,
                    clearFirst: clearFirst,
                    submit: submit,
                    pid: el.pid
                )
                if !nativeSetOk {
                    _ = AXScanner.shared.performNativePress(ref: el.ref)
                    Thread.sleep(forTimeInterval: 0.04)
                    nativeSetOk = AXScanner.shared.performNativeSetValue(
                        ref: el.ref,
                        value: text,
                        clearFirst: clearFirst,
                        submit: submit,
                        pid: el.pid
                    )
                }
                if nativeSetOk {
                    restoreUserFocusIfNeeded(el.pid)
                    KillSwitchMonitor.shared.emitHUDEvent(
                        .highlightElement(rect: el.frame, label: el.label)
                    )
                    KillSwitchMonitor.shared.emitHUDEvent(
                        .clickRipple(point: el.centerPoint, button: .left, clickCount: 1)
                    )
                    let preview = text.count > 28 ? String(text.prefix(28)) + "..." : text
                    KillSwitchMonitor.shared.emitHUDEvent(
                        .statusPill(title: "⌨️ [后台输入] \"\(preview)\"", subtitle: submit ? "输入后自动回车" : nil)
                    )
                    if submit {
                        Thread.sleep(forTimeInterval: 0.05)
                        if !AXScanner.shared.pressSendButton(pid: el.pid) {
                            if let wc = winCtx {
                                SyntheticFocusEnforcer.shared.enforceBackgroundFocus(
                                    pid: wc.pid,
                                    windowID: wc.windowID,
                                    windowBounds: wc.bounds,
                                    activationPoint: el.centerPoint
                                )
                            }
                            Thread.sleep(forTimeInterval: 0.04)
                            postKeyCode(36, flags: [], targetPid: el.pid)
                        }
                    }
                    let ms = Int(Date().timeIntervalSince(startTime) * 1000)
                    KillSwitchMonitor.shared.logAction("⌨️ [AXValue] Typed \"\(preview)\" -> \(el.ref)")
                    return ActionOutcome(
                        action: "type(ax-native)",
                        targetDescription: "\(el.ref) [\(el.role): \(el.label)]",
                        point: el.centerPoint,
                        details: "length=\(text.count), submit=\(submit), mode=ax-value-background",
                        elapsedMs: ms
                    )
                }
            }
        }

        var clickedPoint: ScreenPoint? = nil
        var targetDesc = target ?? "focused field"
        if (target != nil && !target!.isEmpty) || (x != nil && y != nil) {
            let clickRes = try MouseController.shared.click(
                target: target,
                x: x,
                y: y,
                dx: dx,
                dy: dy,
                button: .left,
                clickCount: 1,
                virtualCursor: isVirtual
            )
            clickedPoint = clickRes.point
            targetDesc = clickRes.targetDescription
            Thread.sleep(forTimeInterval: 0.06)
        }

        let targetPid = resolveTargetPid(forVirtualMode: isVirtual)
        let targetCtx = MouseController.shared.lastResolvedTargetContext

        // Fast Path B: Position-based AXValue injection or Browser DOM injection for raw coordinates (e.g. type 2900 882)
        // or OCR elements in background browsers/apps, preventing keystrokes from leaking into the browser address bar!
        if isVirtual, let pid = targetPid, pid > 0 {
            let effectivePt = clickedPoint ?? targetCtx?.bounds.center
            if let pt = effectivePt {
                if !attemptedNativeAXForTarget && !text.hasPrefix("@") && !hasNewlines && !hasImageAttachment && !text.isEmpty &&
                    AXScanner.shared.performNativeSetValueAtPosition(pid: pid, point: pt, value: text, submit: submit) {
                    if submit {
                        Thread.sleep(forTimeInterval: 0.05)
                        if !AXScanner.shared.pressSendButton(pid: pid) {
                            postKeyCode(36, flags: [], targetPid: pid)
                        }
                    }
                    restoreUserFocusIfNeeded(pid)
                    let preview = text.count > 28 ? String(text.prefix(28)) + "..." : text
                    KillSwitchMonitor.shared.emitHUDEvent(
                        .statusPill(title: "⌨️ [后台输入] \"\(preview)\"", subtitle: submit ? "输入后自动回车" : nil)
                    )
                    let ms = Int(Date().timeIntervalSince(startTime) * 1000)
                    KillSwitchMonitor.shared.logAction("⌨️ [AXValue@Pos] Typed \"\(preview)\" at (\(Int(pt.x)),\(Int(pt.y)))")
                    return ActionOutcome(
                        action: "type(ax-pos)",
                        targetDescription: targetDesc,
                        point: pt,
                        details: "length=\(text.count), submit=\(submit), mode=ax-pos-background",
                        elapsedMs: ms
                    )
                }
                if !hasImageAttachment && !text.isEmpty &&
                   BrowserBridgeController.shared.isBrowserApp(nil, pid: pid),
                   BrowserBridgeController.shared.typeAtScreenPoint(
                       text: text,
                       point: pt,
                       windowBounds: targetCtx?.bounds,
                       clearFirst: clearFirst,
                       submit: submit,
                       browser: NSRunningApplication(processIdentifier: pid)?.localizedName
                   ) {
                    restoreUserFocusIfNeeded(pid)
                    let preview = text.count > 28 ? String(text.prefix(28)) + "..." : text
                    KillSwitchMonitor.shared.emitHUDEvent(
                        .statusPill(title: "⌨️ [DOM输入] \"\(preview)\"", subtitle: submit ? "输入后自动回车" : nil)
                    )
                    let ms = Int(Date().timeIntervalSince(startTime) * 1000)
                    KillSwitchMonitor.shared.logAction("⌨️ [BrowserDOM] Typed \"\(preview)\" at (\(Int(pt.x)),\(Int(pt.y)))")
                    return ActionOutcome(
                        action: "type(browser-dom)",
                        targetDescription: targetDesc,
                        point: pt,
                        details: "length=\(text.count), submit=\(submit), mode=browser-dom-background",
                        elapsedMs: ms
                    )
                }
            }
        }

        if isVirtual, let ctx = targetCtx {
            SyntheticFocusEnforcer.shared.enforceBackgroundFocus(
                pid: ctx.pid,
                windowID: ctx.windowID,
                windowBounds: ctx.bounds,
                activationPoint: clickedPoint ?? ctx.bounds.center
            )
            // Re-assert Accessibility focus on the target text field AFTER enforceBackgroundFocus so AppKitDefined
            // subtype 1/4 never resets focus back to an outer container before keystrokes arrive!
            if let tRef = target, !tRef.isEmpty,
               let el = try? ElementSnapshotStore.shared.resolveTarget(tRef),
               el.source == .ax {
                _ = AXScanner.shared.performNativePress(ref: el.ref)
            } else if let pt = clickedPoint ?? targetCtx?.bounds.center {
                AXScanner.shared.focusElementAtPosition(pid: ctx.pid, point: pt)
            }
            Thread.sleep(forTimeInterval: 0.04)
        }

        let preview = text.count > 28 ? String(text.prefix(28)) + "..." : (text.isEmpty && hasImageAttachment ? "[Image Attachment]" : text)
        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "⌨️ 输入文本: \"\(preview)\"", subtitle: submit ? "输入后自动回车" : nil)
        )

        if clearFirst {
            // Select all via AX (works in background Electron/AppKit without menu bar) + Cmd+A then Backspace
            let hasContentToClear: Bool
            if let pid = targetPid, pid > 0 {
                hasContentToClear = AXScanner.shared.selectAllInFocusedElement(pid: pid)
            } else {
                hasContentToClear = true
            }
            if hasContentToClear {
                postKeyCode(0, flags: .maskCommand, targetPid: targetPid)
                Thread.sleep(forTimeInterval: 0.03)
                postKeyCode(51, flags: [], targetPid: targetPid)
                Thread.sleep(forTimeInterval: 0.03)
            }
        }

        // Safe Unicode / clipboard transaction for reliable Chinese/Emoji/multiline injection
        if !text.isEmpty {
            injectTextViaSafePasteboardOrUnicode(text, targetPid: targetPid)
        }

        // Optional image attachment paste (`--image <path>`) with clipboard preservation
        if let imgPath = imagePath, !imgPath.isEmpty {
            if !text.isEmpty {
                postKeyCode(36, flags: .maskShift, targetPid: targetPid)
                Thread.sleep(forTimeInterval: 0.04)
            }
            try pasteImageFile(at: imgPath, targetPid: targetPid)
        }

        if submit {
            // Allow 80ms for ProseMirror/Slate/Lexical DOM state to update and remove `send-button-container--disable`
            Thread.sleep(forTimeInterval: 0.08)
            if let pid = targetPid, AXScanner.shared.pressSendButton(pid: pid) {
                // Sent via native AXPressAction on send-button-container
            } else {
                postKeyCode(36, flags: [], targetPid: targetPid) // Return key
            }
            if hasOffset,
               let targetRef = target,
               let anchorEl = try? ElementSnapshotStore.shared.resolveTarget(targetRef),
               (anchorEl.label.contains("发送") || anchorEl.label.lowercased() == "send") {
                Thread.sleep(forTimeInterval: 0.06)
                _ = try? MouseController.shared.click(
                    target: anchorEl.ref,
                    button: .left,
                    clickCount: 1,
                    virtualCursor: isVirtual
                )
            }
        }

        restoreUserFocusIfNeeded(targetPid)
        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
        KillSwitchMonitor.shared.logAction("⌨️ Typed \"\(preview)\"")
        return ActionOutcome(
            action: "type",
            targetDescription: targetDesc,
            point: clickedPoint,
            details: "length=\(text.count), submit=\(submit), mode=\(isVirtual ? "virtual" : "physical")",
            elapsedMs: ms
        )
    }

    private func resolveTargetPid(forVirtualMode isVirtual: Bool) -> Int32? {
        guard isVirtual else { return nil }
        if let ctxPid = MouseController.shared.lastResolvedTargetContext?.pid, ctxPid > 0 {
            return ctxPid
        }
        if let snapPid = ElementSnapshotStore.shared.currentSnapshot()?.activePid, snapPid > 0 {
            return snapPid
        }
        return nil
    }

    private func injectTextViaSafePasteboardOrUnicode(_ text: String, targetPid: Int32?) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // When typing into a background application (targetPid != nil), inject Unicode key events directly to `pid`
        // (matching Codex `SynthesizedEvent.type(string:)`) because background apps do not own the active macOS
        // menu bar to route Cmd+V `performKeyEquivalent:`, and this avoids touching the user's clipboard!
        // For multiline strings, send `Shift+Enter` (`keyCode 36`, `.maskShift`) between lines so chat inputs
        // (Feishu, WeChat, Slack) insert soft line breaks instead of prematurely submitting.
        if let pid = targetPid {
            for (lineIdx, line) in lines.enumerated() {
                let utf16 = Array(line.utf16)
                let chunkSize = 20
                var idx = 0
                while idx < utf16.count {
                    let end = min(idx + chunkSize, utf16.count)
                    var slice = Array(utf16[idx..<end])
                    if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                       let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                        down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                        up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                        down.postToPid(pid)
                        Thread.sleep(forTimeInterval: 0.012)
                        up.postToPid(pid)
                        Thread.sleep(forTimeInterval: 0.012)
                    }
                    idx = end
                }
                if lineIdx + 1 < lines.count {
                    postKeyCode(36, flags: .maskShift, targetPid: pid)
                    Thread.sleep(forTimeInterval: 0.025)
                }
            }
            return
        }

        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        if pasteboard.setString(normalized, forType: .string) {
            Thread.sleep(forTimeInterval: 0.02)
            // Post Cmd+V (keyCode 9 = 'v')
            postKeyCode(9, flags: .maskCommand, targetPid: targetPid)
            Thread.sleep(forTimeInterval: 0.09)

            // Restore user's original clipboard content
            pasteboard.clearContents()
            if let old = previousString {
                pasteboard.setString(old, forType: .string)
            }
        } else {
            // Fallback to direct Unicode keyboard event
            let utf16 = Array(normalized.utf16)
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                if let pid = targetPid {
                    down.postToPid(pid)
                    up.postToPid(pid)
                } else {
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// Loads an image file into `NSPasteboard.general`, triggers Paste via Accessibility Menu Bar (`performMenuItemPaste`)
    /// or `Cmd+V`, and restores the user's previous clipboard contents.
    private func pasteImageFile(at path: String, targetPid: Int32?) throws {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath),
              let image = NSImage(contentsOfFile: expandedPath) else {
            throw OCUError(
                code: .invalidArguments,
                message: "Could not load image file at '\(path)'.",
                recoveryHint: "Verify that the image file path exists and is a valid PNG/JPEG/TIFF image."
            )
        }

        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        let savedTiff = pasteboard.data(forType: .tiff)

        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        Thread.sleep(forTimeInterval: 0.04)

        if let pid = targetPid, pid > 0 {
            if !AXScanner.shared.performMenuItemPaste(pid: pid) {
                postKeyCode(9, flags: .maskCommand, targetPid: pid)
            }
        } else {
            postKeyCode(9, flags: .maskCommand, targetPid: nil)
        }

        Thread.sleep(forTimeInterval: 0.22)

        pasteboard.clearContents()
        if let oldStr = savedString {
            pasteboard.setString(oldStr, forType: .string)
        } else if let oldTiff = savedTiff, let oldImg = NSImage(data: oldTiff) {
            pasteboard.writeObjects([oldImg])
        }
    }

    private func postKeyCode(_ keyCode: CGKeyCode, flags: CGEventFlags, targetPid: Int32? = nil) {
        if let pid = targetPid {
            SyntheticFocusEnforcer.shared.postSynthesizedKeyCode(keyCode, flags: flags, toPid: pid)
            return
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.018)
        up.post(tap: .cghidEventTap)
    }
}
