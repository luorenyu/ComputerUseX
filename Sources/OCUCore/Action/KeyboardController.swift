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
        virtualCursor: Bool? = nil
    ) throws -> ActionOutcome {
        let startTime = Date()
        let isVirtual = virtualCursor ?? MouseController.shared.useVirtualCursorByDefault
        if isVirtual {
            try KillSwitchMonitor.shared.verifySafeToProceed()
        } else {
            try KillSwitchMonitor.shared.verifySafeToProceed()
        }

        let offsetX = dx ?? 0
        let offsetY = dy ?? 0
        let hasOffset = (abs(offsetX) > 0.1 || abs(offsetY) > 0.1)

        // When targeting an AX text field in a background window with no relative offset, try setting
        // kAXValueAttribute directly so background browsers/Cocoa apps receive text without stealing OS focus
        // or touching the user's system clipboard.
        if isVirtual && !hasOffset,
           let targetRef = target, !targetRef.isEmpty,
           let el = try? ElementSnapshotStore.shared.resolveTarget(targetRef),
           el.source == .ax {
            let winCtx = SyntheticFocusEnforcer.shared.resolveTargetWindow(
                at: el.centerPoint,
                preferredPid: el.pid,
                preferredAppName: el.appName
            )
            let isBackground = winCtx.map {
                !SyntheticFocusEnforcer.shared.isWindowFrontmostOnScreen(windowID: $0.windowID, pid: $0.pid)
            } ?? false

            if isBackground && AXScanner.shared.performNativeSetValue(ref: el.ref, value: text, submit: submit) {
                KillSwitchMonitor.shared.emitHUDEvent(
                    .highlightElement(rect: el.frame, label: "\(el.ref) \(el.label)")
                )
                try MouseController.shared.moveSmoothly(
                    to: el.centerPoint,
                    duration: 0.14,
                    virtualCursor: true,
                    windowID: winCtx?.windowID,
                    pid: el.pid,
                    label: el.ref
                )
                KillSwitchMonitor.shared.emitHUDEvent(
                    .clickRipple(point: el.centerPoint, button: .left, clickCount: 1)
                )
                let preview = text.count > 28 ? String(text.prefix(28)) + "..." : text
                KillSwitchMonitor.shared.emitHUDEvent(
                    .statusPill(title: "⌨️ [后台输入] \"\(preview)\"", subtitle: submit ? "输入后自动回车" : nil)
                )
                if submit {
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
            Thread.sleep(forTimeInterval: 0.08)
        }

        let targetPid = resolveTargetPid(forVirtualMode: isVirtual)
        if isVirtual, let ctx = MouseController.shared.lastResolvedTargetContext {
            SyntheticFocusEnforcer.shared.enforceBackgroundFocus(
                pid: ctx.pid,
                windowID: ctx.windowID,
                windowBounds: ctx.bounds,
                activationPoint: clickedPoint ?? ctx.bounds.center
            )
        }

        let preview = text.count > 28 ? String(text.prefix(28)) + "..." : text
        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "⌨️ 输入文本: \"\(preview)\"", subtitle: submit ? "输入后自动回车" : nil)
        )

        if clearFirst {
            // Cmd + A then Backspace
            postKeyCode(0, flags: .maskCommand, targetPid: targetPid)
            Thread.sleep(forTimeInterval: 0.03)
            postKeyCode(51, flags: [], targetPid: targetPid)
            Thread.sleep(forTimeInterval: 0.03)
        }

        // Safe clipboard transaction for reliable Chinese/Emoji/multi-character injection
        injectTextViaSafePasteboardOrUnicode(text, targetPid: targetPid)

        if submit {
            Thread.sleep(forTimeInterval: 0.05)
            postKeyCode(36, flags: [], targetPid: targetPid) // Return key
        }

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
        // If the target window is visible/unoccluded at the virtual cursor location, prefer standard HID event tap
        // (since performBackgroundClick already focused the target window at that point while preserving physical mouse).
        let loc = MouseController.shared.currentVirtualOrPhysicalLocation
        if let ctx = MouseController.shared.lastResolvedTargetContext,
           let topWin = SyntheticFocusEnforcer.shared.resolveTargetWindow(at: loc),
           topWin.pid == ctx.pid {
            return nil
        }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let ctxPid = MouseController.shared.lastResolvedTargetContext?.pid, ctxPid != frontPid {
            return ctxPid
        }
        if let snapPid = ElementSnapshotStore.shared.currentSnapshot()?.activePid, snapPid != frontPid {
            return snapPid
        }
        return nil
    }

    private func injectTextViaSafePasteboardOrUnicode(_ text: String, targetPid: Int32?) {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
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
            let utf16 = Array(text.utf16)
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
