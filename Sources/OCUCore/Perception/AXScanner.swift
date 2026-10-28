import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

public final class AXScanner: @unchecked Sendable {
    public static let shared = AXScanner()

    private typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias AXUIElementCreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    /// Compensates for Chromium/Electron UI Zoom (`110%`, `125%`, etc.) where the outer `AXWindow` reports
    /// true macOS screen points `(winOrigin, winSize)` while its inner `AXGroup` (`BrowserRootView`) reports
    /// unscaled CSS points `(winOrigin / scale, winSize / scale)`.
    private struct WindowZoomTransform {
        let winOrigin: ScreenPoint
        let contentOrigin: ScreenPoint
        let scaleX: Double
        let scaleY: Double
        let scaledRootHash: CFHashCode

        func toScreen(_ rect: ScreenRect) -> ScreenRect {
            return ScreenRect(
                x: winOrigin.x + (rect.x - contentOrigin.x) * scaleX,
                y: winOrigin.y + (rect.y - contentOrigin.y) * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY
            )
        }

        func toAX(_ point: ScreenPoint) -> ScreenPoint {
            return ScreenPoint(
                x: contentOrigin.x + (point.x - winOrigin.x) / scaleX,
                y: contentOrigin.y + (point.y - winOrigin.y) / scaleY
            )
        }
    }

    private let lock = NSLock()
    private var liveElementMap: [String: AXUIElement] = [:]
    private var liveElementMapByPid: [Int32: [String: AXUIElement]] = [:]
    private var zoomTransformByPid: [Int32: WindowZoomTransform] = [:]
    private var enhancedAXInitializedPids: Set<Int32> = []
    private let getWindowIDFn: AXUIElementGetWindowFn?
    private let createWithRemoteTokenFn: AXUIElementCreateWithRemoteTokenFn?

    private let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXComboBox", "AXMenuButton", "AXMenuItem", "AXMenuBarItem",
        "AXLink", "AXTabGroup", "AXRadioGroup", "AXSlider", "AXIncrementor",
        "AXSwitch", "AXDisclosureTriangle", "AXColorWell", "AXSegmentedControl",
        "AXSearchField", "AXToolbarButton", "AXRow", "AXCell"
    ]

    private let containerRolesToTraverse: Set<String> = [
        "AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup",
        "AXTabGroup", "AXToolbar", "AXSheet", "AXDrawer", "AXMenu", "AXMenuBar",
        "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXWebArea",
        "AXLayoutArea", "AXScrollBar", "AXRadioGroup", "AXUnknown"
    ]

    private init() {
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") {
            self.getWindowIDFn = unsafeBitCast(sym, to: AXUIElementGetWindowFn.self)
        } else {
            self.getWindowIDFn = nil
        }
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken") {
            self.createWithRemoteTokenFn = unsafeBitCast(sym, to: AXUIElementCreateWithRemoteTokenFn.self)
        } else {
            self.createWithRemoteTokenFn = nil
        }
    }

    /// Discovers off-Space or unindexed `AXWindow` elements for `pid` by probing Cocoa accessibility remote tokens
    /// (`_AXUIElementCreateWithRemoteToken`, UIDs `1...128`, reading `kAXWindowAttribute`). Completes in ~25-35ms.
    public func discoverWindowsViaRemoteToken(pid: Int32) -> [AXUIElement] {
        guard pid > 0, let createFn = createWithRemoteTokenFn else { return [] }
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })

        var results: [AXUIElement] = []
        var seenHashes = Set<CFHashCode>()
        for uid in UInt64(1)...UInt64(128) {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: uid) { Data($0) })
            guard let el = createFn(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, 0.02)
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &winRef) == .success,
               let w = winRef,
               CFGetTypeID(w) == AXUIElementGetTypeID() {
                let winEl = w as! AXUIElement
                AXUIElementSetMessagingTimeout(winEl, 0.6)
                let h = CFHash(winEl)
                if seenHashes.insert(h).inserted {
                    results.append(winEl)
                }
            } else if copyStringAttribute(el, kAXRoleAttribute as String) == "AXWindow" {
                AXUIElementSetMessagingTimeout(el, 0.6)
                let h = CFHash(el)
                if seenHashes.insert(h).inserted {
                    results.append(el)
                }
            }
        }
        return results
    }

    public func cgWindowID(for axWindow: AXUIElement) -> UInt32? {
        guard let fn = getWindowIDFn else { return nil }
        var wid: CGWindowID = 0
        if fn(axWindow, &wid) == .success, wid > 0 {
            return wid
        }
        return nil
    }

    public func resolveLiveAXElement(for ref: String, pid: Int32? = nil) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        if let targetPid = pid, targetPid > 0, let pidMap = liveElementMapByPid[targetPid], let el = pidMap[ref] {
            return el
        }
        return liveElementMap[ref]
    }

    /// Activates rich-text `AXTextArea` editors (such as Feishu's `lark__editor--chat` / ProseMirror / Slate)
    /// by setting `kAXMainAttribute` and `kAXFocusedAttribute` on the containing `AXWindow` (without ordering it front),
    /// focusing the `AXTextArea`, and pressing its inner paragraph/text child so the editor enters `lark__editor--focus` mode.
    public func activateRichTextEditor(_ element: AXUIElement) {
        if let winEl: AXUIElement = copyAttribute(element, kAXWindowAttribute as String) {
            _ = AXUIElementSetAttributeValue(winEl, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(winEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute as String),
           let firstChild = children.first {
            _ = AXUIElementPerformAction(firstChild, kAXPressAction as CFString)
            if let grandChildren: [AXUIElement] = copyAttribute(firstChild, kAXChildrenAttribute as String),
               let firstGrand = grandChildren.first {
                _ = AXUIElementPerformAction(firstGrand, kAXPressAction as CFString)
            }
        }
    }

    /// Universal check for transparent overlay / watermark / helper windows across enterprise and desktop apps
    /// (e.g., watermark overlays, screen-recording borders, or empty `AXUnknown` subrole helper windows).
    private func isOverlayHelperWindow(_ win: AXUIElement) -> Bool {
        let title = (copyStringAttribute(win, kAXTitleAttribute as String) ?? "").lowercased()
        if title.contains("watermark") || title.contains("overlay") { return true }
        let subrole = copyStringAttribute(win, kAXSubroleAttribute as String) ?? ""
        if subrole == "AXSystemDialog" { return true }
        if subrole == "AXUnknown" && title.isEmpty { return true }
        if let children: [AXUIElement] = copyAttribute(win, kAXChildrenAttribute as String),
           children.count == 1,
           let firstTitle = copyStringAttribute(children[0], kAXTitleAttribute as String)?.lowercased(),
           firstTitle.contains("watermark") {
            return true
        }
        return false
    }

    /// Universal check for whether an `AXButton` is an enabled Send / Submit button in any chat or composer UI
    /// (Electron/Chromium/Web/AppKit apps such as Slack, Discord, Feishu, WeChat, ChatGPT, Claude, etc.).
    private func isEnabledSendButton(_ element: AXUIElement) -> Bool {
        let role = copyStringAttribute(element, kAXRoleAttribute as String) ?? ""
        guard role == "AXButton" else { return false }
        if (copyBoolAttribute(element, kAXEnabledAttribute as String) ?? true) == false {
            return false
        }
        let classes: [String] = copyAttribute(element, "AXDOMClassList") ?? []
        let domId = (copyStringAttribute(element, "AXDOMIdentifier") ?? "").lowercased()
        let lowerClasses = classes.map { $0.lowercased() }
        if lowerClasses.contains(where: { $0.contains("disable") || $0.contains("readonly") }) || domId.contains("disable") {
            return false
        }
        if lowerClasses.contains(where: {
            $0.contains("send-button") || $0.contains("send_button") ||
            $0.contains("submit-button") || $0.contains("btn-send") || $0.contains("chat-send")
        }) || domId.contains("send-button") || domId.contains("submit-button") {
            return true
        }
        let directLabels = [
            copyStringAttribute(element, kAXTitleAttribute as String),
            copyStringAttribute(element, kAXDescriptionAttribute as String),
            copyStringAttribute(element, kAXHelpAttribute as String)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let sendKeywords: Set<String> = ["发送", "发送消息", "send", "send message"]
        return directLabels.contains(where: { sendKeywords.contains($0) })
    }

    /// Universal check for whether a text control's current `kAXValueAttribute` is empty or merely reflecting
    /// placeholder text (common in ProseMirror/Slate/Lexical/Draft.js contenteditable editors across web & Electron apps).
    private func isPlaceholderOrEmptyValue(_ element: AXUIElement, rawValue: String?) -> Bool {
        let cleanText = (rawValue ?? "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanText.isEmpty { return true }

        let placeholder = copyStringAttribute(element, kAXPlaceholderValueAttribute as String)?
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let ph = placeholder, !ph.isEmpty, cleanText == ph {
            return true
        }
        let desc = copyStringAttribute(element, kAXDescriptionAttribute as String)?
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = desc, !d.isEmpty, cleanText == d {
            return true
        }

        let classes: [String] = copyAttribute(element, "AXDOMClassList") ?? []
        let lowerClasses = classes.map { $0.lowercased() }
        if lowerClasses.contains(where: { $0.contains("placeholder") || $0.contains("is-empty") || $0.contains("editor-empty") }) {
            return true
        }

        let placeholderPrefixes = [
            "发送给 ", "发消息给", "回复 ", "输入消息", "说点什么",
            "Message ", "Reply to ", "Write a message", "Type a message", "Send a message", "Ask anything"
        ]
        if placeholderPrefixes.contains(where: { cleanText.hasPrefix($0) }) {
            return true
        }
        return false
    }

    public func performNativePress(ref: String) -> Bool {
        guard let element = resolveLiveAXElement(for: ref) else {
            return false
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let wid = pid > 0 ? (SyntheticFocusEnforcer.shared.pinnedWindowID(forPid: pid) ?? 0) : 0
        let role = copyStringAttribute(element, kAXRoleAttribute as String) ?? ""
        let isTextRole = (role == "AXTextArea" || role == "AXTextField" || role == "AXSearchField" || role == "AXComboBox")

        return SpaceFocusMonitor.shared.traceSubStep(
            "AXScanner.performNativePress(\(ref):\(role))",
            targetPid: pid,
            windowID: wid
        ) {
            // Direct fast-path for Send / Submit buttons: never blur the input box
            // or post a (0,0) mouse click before pressing Send!
            if self.isEnabledSendButton(element) {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }

            // Only set kAXFocusedAttribute on editable text controls (`isTextRole`).
            // Never set kAXFocusedAttribute on buttons or static text in Chromium/Electron, because doing so
            // steals internal DOM focus away from the active chat `<textarea>` / `contenteditable` editor!
            var focusErr: AXError = .failure
            if isTextRole {
                if role == "AXTextArea" {
                    activateRichTextEditor(element)
                    return true
                }
                focusErr = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }

            let actions = copyActionNames(element)
            if actions.contains(kAXPressAction as String) {
                if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                    return true
                }
            } else if !isTextRole {
                // In Chromium/Electron (e.g. Feishu), leaf `AXStaticText` nodes often lack `"AXPress"` in `copyActionNames`
                // (so calling kAXPressAction on the leaf is a no-op), while their row/card `AXGroup` ancestor implements `"AXPress"`.
                var curr: AXUIElement? = copyAttribute(element, kAXParentAttribute as String)
                for _ in 0..<6 {
                    guard let anc = curr else { break }
                    let ancRole = copyStringAttribute(anc, kAXRoleAttribute as String) ?? ""
                    if ancRole == "AXWindow" || ancRole == "AXApplication" || ancRole == "AXScrollArea" || ancRole == "AXWebArea" {
                        break
                    }
                    if copyActionNames(anc).contains(kAXPressAction as String) {
                        if AXUIElementPerformAction(anc, kAXPressAction as CFString) == .success {
                            return true
                        }
                    }
                    curr = copyAttribute(anc, kAXParentAttribute as String)
                }
            }

            let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if err == .success && (isTextRole || !actions.isEmpty) {
                return true
            }
            // Text inputs (e.g. Electron/Feishu AXTextArea) often do not implement kAXPressAction;
            // focusing them via kAXFocusedAttribute is sufficient to activate the input field.
            if isTextRole && focusErr == .success {
                return true
            }
            return false
        }
    }

    private func copyElementAtScreenPosition(
        _ axApp: AXUIElement,
        pid: Int32,
        point: ScreenPoint,
        _ hitRef: UnsafeMutablePointer<AXUIElement?>
    ) -> AXError {
        lock.lock()
        let transform = zoomTransformByPid[pid]
        lock.unlock()
        if let t = transform {
            let axPt = t.toAX(point)
            let err = AXUIElementCopyElementAtPosition(axApp, Float(axPt.x), Float(axPt.y), hitRef)
            if err == .success, let hit = hitRef.pointee {
                let role = copyStringAttribute(hit, kAXRoleAttribute as String) ?? ""
                if role != "AXWindow" && role != "AXApplication" {
                    return .success
                }
            }
        }
        return AXUIElementCopyElementAtPosition(axApp, Float(point.x), Float(point.y), hitRef)
    }

    /// Performs a native `kAXPressAction` at a screen coordinate `(x, y)` inside `pid` using `AXUIElementCopyElementAtPosition`.
    /// This enables background clicks on `ocrText` elements or raw `(x, y)` coordinates inside Chromium/Electron/WebKit
    /// web pages without requiring foreground window focus.
    public func performNativePressAtPosition(pid: Int32, point: ScreenPoint) -> String? {
        guard pid > 0 else { return nil }

        // Fast Path 1: Check if current snapshot already has an interactive AX element containing `point`
        if let snap = ElementSnapshotStore.shared.currentSnapshot(), snap.activePid == pid {
            let candidates = snap.elements.filter { el in
                el.source == .ax &&
                el.role != "group" &&
                point.x >= el.frame.x - 2 && point.x <= el.frame.x + el.frame.width + 2 &&
                point.y >= el.frame.y - 2 && point.y <= el.frame.y + el.frame.height + 2
            }.sorted { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }

            if let best = candidates.first, performNativePress(ref: best.ref) {
                return "\(best.role):\(best.label)"
            }
        }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.6)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var hitRef: AXUIElement?
        let hitErr = copyElementAtScreenPosition(axApp, pid: pid, point: point, &hitRef)
        guard hitErr == .success, let startEl = hitRef else {
            return nil
        }

        var current: AXUIElement? = startEl
        for _ in 0..<8 {
            guard let el = current else { break }
            let role = copyStringAttribute(el, kAXRoleAttribute as String) ?? ""
            let subrole = copyStringAttribute(el, kAXSubroleAttribute as String) ?? ""
            // Never press generic layout containers or root windows
            if role == "AXWindow" || role == "AXApplication" || role == "AXScrollArea" || role == "AXWebArea" {
                break
            }
            let isTextRole = (role == "AXTextArea" || role == "AXTextField" || role == "AXSearchField" || role == "AXComboBox")
            if isTextRole {
                let focusOk = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
                let pressOk = AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
                if focusOk || pressOk {
                    let lbl = extractLabel(from: el, depth: 0)
                    return "\(role)\(lbl.isEmpty ? "" : ":\(lbl)")"
                }
            }
            if interactiveRoles.contains(role) || role == "AXStaticText" {
                if role != "AXRadioButton" && subrole != "AXTabButton" {
                    _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
                if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
                    let lbl = extractLabel(from: el, depth: 0)
                    return "\(role)\(lbl.isEmpty ? "" : ":\(lbl)")"
                }
            }
            current = copyAttribute(el, kAXParentAttribute as String)
        }
        return nil
    }

    /// Focuses the accessibility element at `point` inside `pid` (via `AXUIElementCopyElementAtPosition` + `kAXFocusedAttribute`)
    /// so that inside multi-process browsers (Chrome/Arc/Edge), DOM focus moves to the clicked `<textarea>` / `<input>`
    /// instead of remaining in the browser's address bar.
    @discardableResult
    public func focusElementAtPosition(pid: Int32, point: ScreenPoint) -> Bool {
        guard pid > 0 else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        var hitRef: AXUIElement?
        if copyElementAtScreenPosition(axApp, pid: pid, point: point, &hitRef) == .success,
           let startEl = hitRef {
            var current: AXUIElement? = startEl
            for _ in 0..<5 {
                guard let el = current else { break }
                let role = copyStringAttribute(el, kAXRoleAttribute as String) ?? ""
                if role == "AXTextArea" {
                    activateRichTextEditor(el)
                    return true
                }
                if role == "AXTextField" || role == "AXSearchField" || role == "AXComboBox" {
                    _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    _ = AXUIElementPerformAction(el, kAXPressAction as CFString)
                    return true
                }
                current = copyAttribute(el, kAXParentAttribute as String)
            }
            // Also check if `startEl` is a wrapper group (such as Feishu's `lark__editor--chat`) that contains an `AXTextArea` child
            func findChildTextArea(_ node: AXUIElement, depth: Int) -> AXUIElement? {
                if depth > 3 { return nil }
                if copyStringAttribute(node, kAXRoleAttribute as String) == "AXTextArea" { return node }
                let ch: [AXUIElement] = copyAttribute(node, kAXChildrenAttribute as String) ?? []
                for c in ch {
                    if let f = findChildTextArea(c, depth: depth + 1) { return f }
                }
                return nil
            }
            if let childTA = findChildTextArea(startEl, depth: 0) {
                activateRichTextEditor(childTA)
                return true
            }
            _ = AXUIElementSetAttributeValue(startEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return true
        }
        // Cross-Space fallback: when the window is on another Space, `AXUIElementCopyElementAtPosition` returns error;
        // check the current snapshot's live AX map for an editable text element near `point`.
        if let snap = ElementSnapshotStore.shared.currentSnapshot(), snap.activePid == pid {
            let textRoles: Set<String> = ["textarea", "textfield", "searchfield", "combobox"]
            if let match = snap.elements.first(where: { el in
                el.source == .ax && textRoles.contains(el.role) &&
                point.x >= el.frame.x - 20 && point.x <= el.frame.x + el.frame.width + 20 &&
                point.y >= el.frame.y - 20 && point.y <= el.frame.y + el.frame.height + 20
            }), let liveEl = resolveLiveAXElement(for: match.ref) {
                if match.role == "textarea" {
                    activateRichTextEditor(liveEl)
                } else {
                    _ = AXUIElementSetAttributeValue(liveEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    _ = AXUIElementPerformAction(liveEl, kAXPressAction as CFString)
                }
                return true
            }
        }
        return false
    }

    /// Selects all text (`CFRange(0, utf16.count)`) in the currently focused accessibility element of `pid`.
    /// This ensures `cmd+a` and `--clear` work reliably in background Electron/Chromium/AppKit windows that
    /// do not own the active macOS menu bar (`performKeyEquivalent:`).
    @discardableResult
    public func selectAllInFocusedElement(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let foc = focusedRef,
              CFGetTypeID(foc) == AXUIElementGetTypeID() else {
            return false
        }
        let el = foc as! AXUIElement
        let text = copyValueAsString(el) ?? ""
        if isPlaceholderOrEmptyValue(el, rawValue: text) {
            return false
        }
        var cfRange = CFRange(location: 0, length: max(0, text.utf16.count))
        if let axRange = AXValueCreate(.cfRange, &cfRange) {
            if AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange) == .success {
                return true
            }
        }
        return true
    }

    /// Invokes the target application's native "Paste / 粘贴" (`Cmd+V`) menu item via Accessibility (`kAXPressAction`).
    /// This allows pasting rich clipboard data (such as `NSImage` attachments in Feishu/WeChat/Slack) into a background
    /// app without requiring the app to own the active foreground macOS menu bar.
    @discardableResult
    public func performMenuItemPaste(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.6)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarObj = menuBarRef,
              CFGetTypeID(menuBarObj) == AXUIElementGetTypeID() else {
            return false
        }
        let menuBar = menuBarObj as! AXUIElement

        func searchPasteItem(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 5 { return nil }
            let role = copyStringAttribute(element, kAXRoleAttribute as String) ?? ""
            if role == "AXMenuItem" {
                let cmdChar = copyStringAttribute(element, kAXMenuItemCmdCharAttribute as String)?.uppercased() ?? ""
                let title = (copyStringAttribute(element, kAXTitleAttribute as String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if cmdChar == "V" || title == "粘贴" || title.lowercased() == "paste" {
                    return element
                }
            }
            let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute as String) ?? []
            for child in children {
                if let found = searchPasteItem(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        if let pasteItem = searchPasteItem(menuBar, depth: 0) {
            return AXUIElementPerformAction(pasteItem, kAXPressAction as CFString) == .success
        }
        return false
    }

    /// Sets `kAXValueAttribute` on an editable element at `point` inside `pid` without stealing OS focus.
    public func performNativeSetValueAtPosition(
        pid: Int32,
        point: ScreenPoint,
        value: String,
        submit: Bool = false
    ) -> Bool {
        guard pid > 0 else { return false }

        if let snap = ElementSnapshotStore.shared.currentSnapshot(), snap.activePid == pid {
            let textRoles: Set<String> = ["textfield", "textarea", "searchfield", "combobox"]
            let candidates = snap.elements.filter { el in
                el.source == .ax &&
                textRoles.contains(el.role) &&
                point.x >= el.frame.x - 4 && point.x <= el.frame.x + el.frame.width + 4 &&
                point.y >= el.frame.y - 4 && point.y <= el.frame.y + el.frame.height + 4
            }.sorted { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }

            if let best = candidates.first, performNativeSetValue(ref: best.ref, value: value, submit: submit) {
                return true
            }
        }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.6)
        var hitRef: AXUIElement?
        guard copyElementAtScreenPosition(axApp, pid: pid, point: point, &hitRef) == .success,
              let startEl = hitRef else {
            return false
        }
        var current: AXUIElement? = startEl
        for _ in 0..<5 {
            guard let el = current else { break }
            let role = copyStringAttribute(el, kAXRoleAttribute as String) ?? ""
            if role == "AXWindow" || role == "AXApplication" { break }
            let isTextRole = (role == "AXTextArea" || role == "AXTextField" || role == "AXSearchField" || role == "AXComboBox")
            var settable: DarwinBoolean = false
            let canSet = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            if isTextRole || canSet {
                let beforeVal = copyValueAsString(el)?.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementPerformAction(el, kAXPressAction as CFString)
                let didSet: Bool
                if role == "AXTextArea" {
                    // Rich-text editors (ProseMirror/Slate/Lexical in Feishu/Electron) require kAXSelectedTextAttribute
                    // after kAXPressAction initializes the caret selection. Never fall back to kAXValueAttribute on
                    // AXTextArea because kAXValueAttribute mutates raw DOM text without updating ProseMirror state.
                    Thread.sleep(forTimeInterval: 0.05)
                    didSet = (AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, value as CFTypeRef) == .success)
                } else {
                    didSet = (AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef) == .success) ||
                             (AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, value as CFTypeRef) == .success)
                }
                if didSet {
                    let expected = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    for _ in 0..<3 {
                        Thread.sleep(forTimeInterval: 0.03)
                        if let afterVal = copyValueAsString(el)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           (afterVal == expected || afterVal.contains(expected) || (afterVal != beforeVal && !afterVal.isEmpty)) {
                            if submit {
                                _ = AXUIElementPerformAction(el, kAXConfirmAction as CFString)
                            }
                            return true
                        }
                    }
                }
            }
            current = copyAttribute(el, kAXParentAttribute as String)
        }
        return false
    }

    /// Invokes the target application's native "Paste / 粘贴" (`Cmd+V`) menu item via Accessibility (`kAXPressAction`)
    /// with a temporary string payload on `NSPasteboard.general`, restoring the user's original clipboard afterwards.
    @discardableResult
    public func performMenuItemPasteWithString(pid: Int32, text: String) -> Bool {
        guard pid > 0, !text.isEmpty else { return false }
        let wid = SyntheticFocusEnforcer.shared.pinnedWindowID(forPid: pid) ?? 0
        SyntheticFocusEnforcer.shared.enforceBackgroundFocus(
            pid: pid,
            windowID: wid,
            windowBounds: ScreenRect(x: 0, y: 0, width: 0, height: 0),
            activationPoint: ScreenPoint(x: 0, y: 0)
        )
        Thread.sleep(forTimeInterval: 0.03)
        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return false }
        Thread.sleep(forTimeInterval: 0.02)
        let pasted = performMenuItemPaste(pid: pid)
        Thread.sleep(forTimeInterval: 0.10)
        pb.clearContents()
        if let old = savedString {
            pb.setString(old, forType: .string)
        }
        return pasted
    }

    /// Sets `kAXSelectedTextAttribute` (for rich-text `AXTextArea`) or `kAXValueAttribute` (for `AXTextField`)
    /// in the background without stealing OS focus, and performs read-back verification.
    public func performNativeSetValue(ref: String, value: String, clearFirst: Bool = false, submit: Bool = false, pid: Int32? = nil) -> Bool {
        guard let element = resolveLiveAXElement(for: ref, pid: pid) else {
            return false
        }
        var targetPid: pid_t = pid ?? 0
        if targetPid <= 0 {
            AXUIElementGetPid(element, &targetPid)
        }
        let wid = targetPid > 0 ? (SyntheticFocusEnforcer.shared.pinnedWindowID(forPid: targetPid) ?? 0) : 0
        let role = copyStringAttribute(element, kAXRoleAttribute as String) ?? ""

        return SpaceFocusMonitor.shared.traceSubStep(
            "AXScanner.performNativeSetValue(\(ref):\(role))",
            targetPid: targetPid,
            windowID: wid
        ) {
            let beforeVal = copyValueAsString(element)?.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let err: AXError
            if role == "AXTextArea" {
                activateRichTextEditor(element)
                for _ in 0..<3 {
                    Thread.sleep(forTimeInterval: 0.025)
                    var selRange: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRange) == .success,
                       selRange != nil {
                        break
                    }
                }
                let isPlaceholder = isPlaceholderOrEmptyValue(element, rawValue: beforeVal)
                if clearFirst && !isPlaceholder {
                    var fullRange = CFRange(location: 0, length: max(0, (beforeVal ?? "").utf16.count))
                    if let axFull = AXValueCreate(.cfRange, &fullRange) {
                        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axFull)
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                }
                err = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, value as CFTypeRef)
            } else {
                _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
                let valErr = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
                err = (valErr == .success) ? valErr : AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, value as CFTypeRef)
            }
            guard err == .success else { return false }

            let expected = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedPrefix = String(expected.prefix(120))
            func checkValueVerified() -> Bool {
                guard let rawAfter = copyValueAsString(element) else { return false }
                let afterVal = rawAfter
                    .replacingOccurrences(of: "\u{200B}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanBefore = (beforeVal ?? "")
                    .replacingOccurrences(of: "\u{200B}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if afterVal == expected ||
                   afterVal.contains(expected) ||
                   (!expectedPrefix.isEmpty && afterVal.contains(expectedPrefix)) {
                    return true
                }
                if afterVal != cleanBefore && !isPlaceholderOrEmptyValue(element, rawValue: rawAfter) {
                    return true
                }
                return false
            }

            var verified = false
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 0.03)
                if checkValueVerified() {
                    verified = true
                    break
                }
            }
            guard verified else {
                return false
            }
            if submit {
                _ = AXUIElementPerformAction(element, kAXConfirmAction as CFString)
            }
            return true
        }
    }

    /// Finds an enabled Send / Submit button inside `pid`'s main window
    /// and triggers `kAXPressAction` directly so `--submit` works reliably across macOS Spaces.
    public func pressSendButton(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let wid = SyntheticFocusEnforcer.shared.pinnedWindowID(forPid: pid) ?? 0
        return SpaceFocusMonitor.shared.traceSubStep(
            "AXScanner.pressSendButton",
            targetPid: pid,
            windowID: wid
        ) {
            // Fast Path 1: Check the live AX element map from the most recent snapshot for `pid`.
            lock.lock()
            let pidMap = liveElementMapByPid[pid] ?? liveElementMap
            lock.unlock()
            for (_, el) in pidMap {
                if self.isEnabledSendButton(el) {
                    if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
            }

            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.8)

            // Fast Path 2: Check siblings of `kAXFocusedUIElementAttribute` (the focused text input often sits inside
            // a composer container whose sibling is the Send / Submit button)
            if let focEl: AXUIElement = copyAttribute(axApp, kAXFocusedUIElementAttribute as String) {
                var curr: AXUIElement? = focEl
                for _ in 0..<4 {
                    guard let c = curr else { break }
                    if let children: [AXUIElement] = copyAttribute(c, kAXChildrenAttribute as String) {
                        for child in children.reversed() {
                            if self.isEnabledSendButton(child) {
                                if AXUIElementPerformAction(child, kAXPressAction as CFString) == .success {
                                    return true
                                }
                            }
                        }
                    }
                    curr = copyAttribute(c, kAXParentAttribute as String)
                }
            }

            var candidateWins: [AXUIElement] = []
            if let wins: [AXUIElement] = copyAttribute(axApp, kAXWindowsAttribute as String) {
                candidateWins.append(contentsOf: wins.filter { !self.isOverlayHelperWindow($0) })
            }
            for attr in [kAXMainWindowAttribute as String, kAXFocusedWindowAttribute as String] {
                if let w: AXUIElement = copyAttribute(axApp, attr),
                   !self.isOverlayHelperWindow(w),
                   !candidateWins.contains(where: { CFHash($0) == CFHash(w) }) {
                    candidateWins.insert(w, at: 0)
                }
            }
            if let focEl: AXUIElement = copyAttribute(axApp, kAXFocusedUIElementAttribute as String) {
                if let focWin: AXUIElement = copyAttribute(focEl, kAXWindowAttribute as String),
                   !self.isOverlayHelperWindow(focWin),
                   !candidateWins.contains(where: { CFHash($0) == CFHash(focWin) }) {
                    candidateWins.insert(focWin, at: 0)
                } else {
                    var curr: AXUIElement? = focEl
                    for _ in 0..<24 {
                        guard let c = curr else { break }
                        if copyStringAttribute(c, kAXRoleAttribute as String) == "AXWindow" {
                            if !self.isOverlayHelperWindow(c),
                               !candidateWins.contains(where: { CFHash($0) == CFHash(c) }) {
                                candidateWins.insert(c, at: 0)
                            }
                            break
                        }
                        curr = copyAttribute(c, kAXParentAttribute as String)
                    }
                }
            }
            if candidateWins.isEmpty {
                for w in discoverWindowsViaRemoteToken(pid: pid) {
                    if !self.isOverlayHelperWindow(w),
                       !candidateWins.contains(where: { CFHash($0) == CFHash(w) }) {
                        candidateWins.append(w)
                    }
                }
            }
            guard let win = candidateWins.first else { return false }
            var pressed = false
            func walk(_ el: AXUIElement, depth: Int) {
                if depth > 25 || pressed { return }
                if self.isEnabledSendButton(el) {
                    pressed = (AXUIElementPerformAction(el, kAXPressAction as CFString) == .success)
                    return
                }
                if let children: [AXUIElement] = copyAttribute(el, kAXChildrenAttribute as String) {
                    for child in children.reversed() {
                        walk(child, depth: depth + 1)
                        if pressed { return }
                    }
                }
            }
            walk(win, depth: 0)
            return pressed
        }
    }

    /// Performs secondary AX actions (`AXShowMenu`, `AXIncrement`, `AXDecrement`, `AXPick`, `AXCancel`) on an element.
    public func performSecondaryAction(ref: String, actionName: String = "AXShowMenu") -> Bool {
        guard let element = resolveLiveAXElement(for: ref) else {
            return false
        }
        let normalized: String
        switch actionName.lowercased() {
        case "menu", "showmenu", "axshowmenu", "contextmenu":
            normalized = kAXShowMenuAction as String
        case "increment", "axincrement", "up", "+":
            normalized = kAXIncrementAction as String
        case "decrement", "axdecrement", "down", "-":
            normalized = kAXDecrementAction as String
        case "cancel", "axcancel":
            normalized = kAXCancelAction as String
        case "pick", "axpick":
            normalized = kAXPickAction as String
        default:
            normalized = actionName
        }
        return AXUIElementPerformAction(element, normalized as CFString) == .success
    }

    /// Moves a window directly in the background via `kAXPositionAttribute` without moving the physical mouse cursor.
    public func moveWindowBackground(pid: Int32, windowID: UInt32?, to newOrigin: ScreenPoint) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        let allWindows: [AXUIElement] = copyAttribute(axApp, kAXWindowsAttribute as String) ?? []
        guard let targetWin = (windowID.flatMap { wid in allWindows.first(where: { cgWindowID(for: $0) == wid }) }) ?? allWindows.first else {
            return false
        }
        var pt = CGPoint(x: newOrigin.x, y: newOrigin.y)
        guard let axVal = AXValueCreate(.cgPoint, &pt) else { return false }
        return AXUIElementSetAttributeValue(targetWin, kAXPositionAttribute as CFString, axVal) == .success
    }

    /// Unminimizes, raises (`kAXRaiseAction`), and activates the exact window matching `(pid, windowID)` when the user clicks the Mini PiP preview.
    public func raiseWindow(pid: Int32, windowID: UInt32) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.unhide()
            app.activate()
        }
        let axApp = AXUIElementCreateApplication(pid)
        let allWindows: [AXUIElement] = copyAttribute(axApp, kAXWindowsAttribute as String) ?? []
        if let targetWin = allWindows.first(where: { cgWindowID(for: $0) == windowID }) ?? allWindows.first {
            AXUIElementSetAttributeValue(targetWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(targetWin, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(targetWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(targetWin, kAXRaiseAction as CFString)
        }
    }

    public func scanApplication(
        appNameFilter: String? = nil,
        preferredWindowID: UInt32? = nil,
        windowTitleFilter: String? = nil,
        maxDepth: Int = 52,
        maxElements: Int = 500,
        updateLiveMap: Bool = true
    ) -> (
        appName: String,
        pid: Int32,
        windowID: UInt32?,
        windowTitle: String?,
        windowFrame: ScreenRect?,
        elements: [UIElementRef],
        rawAXMap: [String: AXUIElement]
    ) {
        let workspace = NSWorkspace.shared
        let targetApp: NSRunningApplication?

        if let filter = appNameFilter, !filter.isEmpty {
            let lower = filter.lowercased()
            targetApp = workspace.runningApplications.first(where: { app in
                (app.localizedName?.lowercased() == lower) ||
                (app.bundleIdentifier?.lowercased() == lower)
            }) ?? workspace.runningApplications.first(where: { app in
                (app.localizedName?.lowercased().contains(lower) == true) ||
                (app.bundleIdentifier?.lowercased().contains(lower) == true)
            })
        } else if let prefWid = preferredWindowID, prefWid > 0,
                  let infoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
                  let winInfo = infoList.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == prefWid }),
                  let winPid = winInfo[kCGWindowOwnerPID as String] as? Int32,
                  let ownerApp = NSRunningApplication(processIdentifier: winPid) {
            targetApp = ownerApp
        } else {
            targetApp = workspace.frontmostApplication
        }

        guard let app = targetApp else {
            return (appNameFilter ?? "Unknown", 0, nil, nil, nil, [], [:])
        }

        let appName = app.localizedName ?? app.bundleIdentifier ?? "App"
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.9)

        // Enable accessibility tree generation for Electron / Chromium / Qt / WeChat apps only if not already active
        let alreadyEnhanced = copyBoolAttribute(axApp, "AXEnhancedUserInterface") ?? false
        if !alreadyEnhanced {
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        lock.lock()
        let isFirstAXAttach = enhancedAXInitializedPids.insert(pid).inserted
        lock.unlock()
        if isFirstAXAttach && !alreadyEnhanced {
            Thread.sleep(forTimeInterval: 0.14)
        }

        let desktopBounds = PermissionManager.shared.desktopBounds()
        var resolvedWindowID: UInt32? = nil
        var windowTitle: String? = nil
        var primaryWindowFrame: ScreenRect? = nil
        var roots: [AXUIElement] = []

        var allWindows: [AXUIElement] = copyAttribute(axApp, kAXWindowsAttribute as String) ?? []
        // When an application window is on another macOS Space (virtual desktop), macOS omits it from
        // `kAXWindowsAttribute` and `kAXChildrenAttribute`, but STILL exposes it via `kAXMainWindowAttribute`
        // and `kAXFocusedWindowAttribute`! Always merge those into `allWindows` for cross-Space operation.
        for attr in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            if let winEl: AXUIElement = copyAttribute(axApp, attr),
               copyStringAttribute(winEl, kAXRoleAttribute as String) == "AXWindow" {
                let h = CFHash(winEl)
                if !allWindows.contains(where: { CFHash($0) == h }) {
                    allWindows.append(winEl)
                }
            }
        }
        // Even when an off-Space Electron/Chromium window is omitted from `kAXWindowsAttribute`,
        // `kAXMainWindowAttribute`, and `kAXFocusedWindowAttribute`, `kAXFocusedUIElementAttribute` still
        // points to the focused element inside that window. Walk up to its `AXWindow` to recover the window root!
        if let focEl: AXUIElement = copyAttribute(axApp, kAXFocusedUIElementAttribute as String) {
            if let focWin: AXUIElement = copyAttribute(focEl, kAXWindowAttribute as String),
               copyStringAttribute(focWin, kAXRoleAttribute as String) == "AXWindow" {
                let h = CFHash(focWin)
                if !allWindows.contains(where: { CFHash($0) == h }) {
                    allWindows.append(focWin)
                }
            } else {
                var curr: AXUIElement? = focEl
                for _ in 0..<24 {
                    guard let c = curr else { break }
                    if copyStringAttribute(c, kAXRoleAttribute as String) == "AXWindow" {
                        let h = CFHash(c)
                        if !allWindows.contains(where: { CFHash($0) == h }) {
                            allWindows.append(c)
                        }
                        break
                    }
                    curr = copyAttribute(c, kAXParentAttribute as String)
                }
            }
        }
        if !allWindows.contains(where: { !self.isOverlayHelperWindow($0) }) {
            for w in discoverWindowsViaRemoteToken(pid: pid) {
                let h = CFHash(w)
                if !allWindows.contains(where: { CFHash($0) == h }) {
                    allWindows.append(w)
                }
            }
        }
        allWindows.sort { a, b in
            let aOverlay = isOverlayHelperWindow(a)
            let bOverlay = isOverlayHelperWindow(b)
            if aOverlay != bOverlay { return !aOverlay }
            let aStd = (copyStringAttribute(a, kAXSubroleAttribute as String) == "AXStandardWindow")
            let bStd = (copyStringAttribute(b, kAXSubroleAttribute as String) == "AXStandardWindow")
            if aStd != bStd { return aStd }
            return false
        }
        let nonOverlayWindows = allWindows.filter { !isOverlayHelperWindow($0) }
        if !nonOverlayWindows.isEmpty {
            allWindows = nonOverlayWindows
        }
        let visibleWindows = allWindows.filter { win in
            let isMin: Bool = copyAttribute(win, kAXMinimizedAttribute as String) ?? false
            return !isMin
        }

        let rawTargetWinID = preferredWindowID ?? SyntheticFocusEnforcer.shared.pinnedWindowID(forPid: pid)
        let targetWinID: UInt32? = {
            guard let wid = rawTargetWinID else { return nil }
            if preferredWindowID == nil,
               let matched = allWindows.first(where: { cgWindowID(for: $0) == wid }),
               isOverlayHelperWindow(matched) {
                return nil
            }
            return wid
        }()

        if let titleFilter = windowTitleFilter, !titleFilter.isEmpty,
           let matchedByTitle = (visibleWindows + allWindows).first(where: {
               copyStringAttribute($0, kAXTitleAttribute as String)?.localizedCaseInsensitiveContains(titleFilter) == true
           }) {
            resolvedWindowID = cgWindowID(for: matchedByTitle)
            windowTitle = copyStringAttribute(matchedByTitle, kAXTitleAttribute as String)
            primaryWindowFrame = copyFrame(matchedByTitle)
            roots.append(matchedByTitle)
        } else if let desiredWid = targetWinID {
            if let matchedWin = allWindows.first(where: { cgWindowID(for: $0) == desiredWid }) {
                resolvedWindowID = desiredWid
                windowTitle = copyStringAttribute(matchedWin, kAXTitleAttribute as String)
                primaryWindowFrame = copyFrame(matchedWin)
                roots.append(matchedWin)
            } else {
                let cgWins = AppWorkspaceController.shared.listRunningApps().first(where: { $0.pid == pid })?.windows ?? []
                if cgWins.contains(where: { UInt32($0.windowId) == desiredWid }) {
                    // Target window ID is an active CGWindow (e.g., WeChat's content window)
                    resolvedWindowID = desiredWid
                    roots.append(contentsOf: visibleWindows.isEmpty ? allWindows : visibleWindows)
                } else if let firstLive = visibleWindows.first ?? allWindows.first {
                    // Pinned window ID was closed; switch to the new live window
                    resolvedWindowID = cgWindowID(for: firstLive)
                    windowTitle = copyStringAttribute(firstLive, kAXTitleAttribute as String)
                    primaryWindowFrame = copyFrame(firstLive)
                    roots.append(firstLive)
                }
            }
        } else if let focusedWindow: AXUIElement = copyAttribute(axApp, kAXFocusedWindowAttribute as String),
                  (copyAttribute(focusedWindow, kAXMinimizedAttribute as String) as Bool? ?? false) == false,
                  !isOverlayHelperWindow(focusedWindow) {
            resolvedWindowID = cgWindowID(for: focusedWindow)
            windowTitle = copyStringAttribute(focusedWindow, kAXTitleAttribute as String)
            primaryWindowFrame = copyFrame(focusedWindow)
            roots.append(focusedWindow)
        } else if let mainWindow: AXUIElement = copyAttribute(axApp, kAXMainWindowAttribute as String),
                  (copyAttribute(mainWindow, kAXMinimizedAttribute as String) as Bool? ?? false) == false,
                  !isOverlayHelperWindow(mainWindow) {
            resolvedWindowID = cgWindowID(for: mainWindow)
            windowTitle = copyStringAttribute(mainWindow, kAXTitleAttribute as String)
            primaryWindowFrame = copyFrame(mainWindow)
            roots.append(mainWindow)
        } else if let firstVisible = visibleWindows.first ?? allWindows.first {
            resolvedWindowID = cgWindowID(for: firstVisible)
            windowTitle = copyStringAttribute(firstVisible, kAXTitleAttribute as String)
            primaryWindowFrame = copyFrame(firstVisible)
            roots.append(firstVisible)
        }

        // Fallback to CGWindowList bounds if AXWindow frame or windowID was not reported
        if primaryWindowFrame == nil || resolvedWindowID == nil {
            let appWindows = AppWorkspaceController.shared.listRunningApps()
                .first(where: { $0.pid == pid })?.windows ?? []
            let matchedCGWin = targetWinID.flatMap { wid in
                appWindows.first(where: { UInt32($0.windowId) == wid })
            } ?? appWindows.first
            if let cgWin = matchedCGWin {
                if primaryWindowFrame == nil {
                    primaryWindowFrame = cgWin.frame
                }
                if resolvedWindowID == nil {
                    resolvedWindowID = UInt32(cgWin.windowId)
                }
                if windowTitle == nil || windowTitle?.isEmpty == true {
                    windowTitle = cgWin.title
                }
            }
        }

        if let wid = resolvedWindowID, wid > 0 {
            SyntheticFocusEnforcer.shared.pinWindow(pid: pid, windowID: wid)
        }

        // Automatically detect modal AXSheets or out-of-process macOS File Picker (`openAndSavePanelService`)
        // overlapping the target window so file upload dialogs in Chrome/Firefox/WeChat are visible in the AX tree!
        for win in roots {
            if let sheets: [AXUIElement] = copyAttribute(win, "AXSheets"), !sheets.isEmpty {
                roots.insert(contentsOf: sheets, at: 0)
            }
        }
        if let panelServiceApp = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.appkit.xpc.openAndSavePanelService"
        }) {
            let panelAX = AXUIElementCreateApplication(panelServiceApp.processIdentifier)
            AXUIElementSetMessagingTimeout(panelAX, 0.5)
            if let panelWins: [AXUIElement] = copyAttribute(panelAX, kAXWindowsAttribute as String), !panelWins.isEmpty {
                roots.insert(contentsOf: panelWins, at: 0)
            }
        }

        if roots.isEmpty, let winFrame = primaryWindowFrame {
            // Electron/Chromium background windows sometimes omit their NSWindow from `kAXWindowsAttribute`
            // until hit-tested via `AXUIElementCopyElementAtPosition`. Probe inside `winFrame` to recover the AXWindow.
            let probePoints = [
                winFrame.center,
                ScreenPoint(x: winFrame.x + min(180, winFrame.width * 0.25), y: winFrame.y + min(180, winFrame.height * 0.25)),
                ScreenPoint(x: winFrame.x + winFrame.width * 0.5, y: winFrame.y + max(40, winFrame.height - 80))
            ]
            for pt in probePoints {
                var hitRef: AXUIElement?
                if AXUIElementCopyElementAtPosition(axApp, Float(pt.x), Float(pt.y), &hitRef) == .success,
                   let hitEl = hitRef {
                    if let winEl: AXUIElement = copyAttribute(hitEl, kAXWindowAttribute as String) {
                        roots.append(winEl)
                        break
                    }
                    var curr: AXUIElement? = hitEl
                    var topCandidate: AXUIElement = hitEl
                    for _ in 0..<12 {
                        guard let c = curr else { break }
                        let r = copyStringAttribute(c, kAXRoleAttribute as String) ?? ""
                        if r == "AXWindow" {
                            topCandidate = c
                            break
                        }
                        if r == "AXApplication" { break }
                        topCandidate = c
                        curr = copyAttribute(c, kAXParentAttribute as String)
                    }
                    roots.append(topCandidate)
                    break
                }
            }
        }

        if roots.isEmpty {
            roots.append(axApp)
            if let menuBar: AXUIElement = copyAttribute(axApp, kAXMenuBarAttribute as String) {
                roots.append(menuBar)
            }
        }

        // Detect Chromium/Electron UI Zoom (`110%`, `125%`, etc.) where `AXWindow` reports real macOS screen points
        // `(3242, 177, 1515, 948)` while its inner `AXGroup` (`BrowserRootView`) reports unscaled CSS points
        // `(2947, 161, 1377, 862)` (`= winFrame / zoomFactor`).
        var detectedZoomTransform: WindowZoomTransform? = nil
        if let wf = primaryWindowFrame, wf.width > 120, wf.height > 120 {
            for r in roots {
                guard copyStringAttribute(r, kAXRoleAttribute as String) == "AXWindow",
                      let children: [AXUIElement] = copyAttribute(r, kAXChildrenAttribute as String) else {
                    continue
                }
                for child in children {
                    guard copyStringAttribute(child, kAXRoleAttribute as String) == "AXGroup",
                          let cf = copyFrame(child),
                          cf.width > 100, cf.height > 100 else {
                        continue
                    }
                    let sx = wf.width / cf.width
                    let sy = wf.height / cf.height
                    let uniformScale = abs(sx - sy) < 0.025 && sx >= 0.5 && sx <= 3.0 && abs(sx - 1.0) > 0.02
                    let originMatchesScaled = abs(cf.x * sx - wf.x) < 20.0 && abs(cf.y * sy - wf.y) < 20.0
                    let originMatchesDirect = abs(cf.x - wf.x) < 12.0 && abs(cf.y - wf.y) < 40.0
                    if uniformScale && (originMatchesScaled || originMatchesDirect) {
                        detectedZoomTransform = WindowZoomTransform(
                            winOrigin: ScreenPoint(x: wf.x, y: wf.y),
                            contentOrigin: ScreenPoint(x: cf.x, y: cf.y),
                            scaleX: sx,
                            scaleY: sy,
                            scaledRootHash: CFHash(child)
                        )
                        break
                    }
                }
                if detectedZoomTransform != nil { break }
            }
        }
        lock.lock()
        if let zt = detectedZoomTransform {
            zoomTransformByPid[pid] = zt
        } else {
            zoomTransformByPid.removeValue(forKey: pid)
        }
        lock.unlock()

        if let focEl: AXUIElement = copyAttribute(axApp, kAXFocusedUIElementAttribute as String) {
            let focRole = copyStringAttribute(focEl, kAXRoleAttribute as String) ?? ""
            if focRole != "AXWebArea" && focRole != "AXWindow" && focRole != "AXGroup" && focRole != "AXApplication" {
                roots.insert(focEl, at: 0)
            }
        }

        var collected: [(UIElementRef, AXUIElement)] = []
        var visitedHashes = Set<CFHashCode>()
        let deadline = Date().addingTimeInterval(2.4)
        // Expand valid bounds to the union of `desktopBounds` and `primaryWindowFrame` (padded by 200pt)
        // so windows positioned partially beyond an external monitor's right/bottom edge still retain all their AX elements!
        let validBounds: ScreenRect = {
            guard let wf = primaryWindowFrame, wf.width > 10, wf.height > 10 else {
                return desktopBounds
            }
            let minX = min(desktopBounds.x, wf.x - 200.0)
            let minY = min(desktopBounds.y, wf.y - 200.0)
            let maxX = max(desktopBounds.maxX, wf.maxX + 200.0)
            let maxY = max(desktopBounds.maxY, wf.maxY + 200.0)
            return ScreenRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }()

        func traverse(
            _ element: AXUIElement,
            depth: Int,
            branchDeadline: Date,
            branchMaxElements: Int,
            reverseChildren: Bool,
            inScaledSubtree: Bool
        ) {
            let now = Date()
            guard depth <= maxDepth,
                  collected.count < maxElements,
                  collected.count < branchMaxElements,
                  now < deadline,
                  now < branchDeadline else {
                return
            }

            let hash = CFHash(element)
            if visitedHashes.contains(hash) { return }
            visitedHashes.insert(hash)

            let isEnteringScaledSubtree = inScaledSubtree || (detectedZoomTransform?.scaledRootHash == hash)

            let role = copyStringAttribute(element, kAXRoleAttribute as String) ?? "AXUnknown"
            let subrole: String? = (role == "AXButton" || role == "AXTextField")
                ? copyStringAttribute(element, kAXSubroleAttribute as String)
                : nil

            let isCandidateRole = interactiveRoles.contains(role) ||
                role == "AXStaticText" ||
                role == "AXRow" ||
                role == "AXCell" ||
                subrole == "AXCloseButton" ||
                subrole == "AXMinimizeButton" ||
                subrole == "AXZoomButton" ||
                subrole == "AXSearchField"

            if isCandidateRole, let rawRect = copyFrame(element) {
                let isNativeTrafficLight = (subrole == "AXCloseButton" || subrole == "AXMinimizeButton" || subrole == "AXZoomButton")
                let rect: ScreenRect
                if let zt = detectedZoomTransform, (isEnteringScaledSubtree || (depth == 0 && role != "AXWindow")) && !isNativeTrafficLight {
                    rect = zt.toScreen(rawRect)
                } else {
                    rect = rawRect
                }
                let isStaticText = (role == "AXStaticText")
                let valueStr = copyValueAsString(element)
                let title = (isStaticText && valueStr != nil && !valueStr!.isEmpty)
                    ? nil
                    : copyStringAttribute(element, kAXTitleAttribute as String)
                let desc = isStaticText ? nil : copyStringAttribute(element, kAXDescriptionAttribute as String)
                let placeholder = isStaticText ? nil : copyStringAttribute(element, kAXPlaceholderValueAttribute as String)
                let help = isStaticText ? nil : copyStringAttribute(element, kAXHelpAttribute as String)
                let enabled = isStaticText ? true : (copyBoolAttribute(element, kAXEnabledAttribute as String) ?? true)
                let focused = isStaticText ? false : (copyBoolAttribute(element, kAXFocusedAttribute as String) ?? false)
                let isOnScreen = rect.width >= 6 && rect.height >= 6 &&
                    rect.intersectionArea(with: validBounds) > 0 &&
                    rect.width <= validBounds.width * 0.98 &&
                    rect.height <= validBounds.height * 0.98

                if isOnScreen {
                    var displayLabel = [title, desc, placeholder, valueStr, help]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first(where: { !$0.isEmpty }) ?? ""

                    let isInteractive = interactiveRoles.contains(role) ||
                        subrole == "AXCloseButton" ||
                        subrole == "AXMinimizeButton" ||
                        subrole == "AXZoomButton" ||
                        subrole == "AXSearchField"

                    if displayLabel.isEmpty && isInteractive {
                        displayLabel = extractLabel(from: element, depth: 0)
                    }

                    let isMeaningfulText = (role == "AXStaticText" && !displayLabel.isEmpty && displayLabel.count <= 1000)

                    // For rows/cells, only include if they have a non-empty label or reasonable height
                    let shouldKeep: Bool
                    if role == "AXRow" || role == "AXCell" {
                        shouldKeep = !displayLabel.isEmpty && rect.height <= 120
                    } else {
                        shouldKeep = isInteractive || isMeaningfulText
                    }

                    if shouldKeep {
                        let friendlyRole = normalizeRole(role: role, subrole: subrole)
                        let finalLabel = displayLabel.isEmpty ? friendlyRole : displayLabel
                        let isDuplicate = collected.contains { existing in
                            existing.0.label == finalLabel &&
                            existing.0.frame.intersectionOverUnion(with: rect) > 0.85
                        }
                        if !isDuplicate {
                            let item = UIElementRef(
                                ref: "",
                                source: .ax,
                                role: friendlyRole,
                                label: finalLabel,
                                value: valueStr,
                                frame: rect,
                                enabled: enabled,
                                focused: focused,
                                appName: appName,
                                pid: pid,
                                windowID: resolvedWindowID,
                                windowTitle: windowTitle
                            )
                            collected.append((item, element))
                        }
                    }
                }
            }

            if containerRolesToTraverse.contains(role) || role == "AXGenericElement" || depth < 8 {
                let isWebArea = (role == "AXWebArea")
                let effectiveBranchDeadline = isWebArea
                    ? min(deadline, Date().addingTimeInterval(0.95))
                    : branchDeadline
                // Give each AXWebArea its own element cap so one dense pane (e.g. a chat message list)
                // can never consume 100% of maxElements and starve another AXWebArea (e.g. the left sidebar).
                let effectiveBranchMaxElements = isWebArea
                    ? min(maxElements, collected.count + 260)
                    : branchMaxElements
                let effectiveReverseChildren: Bool = {
                    if isWebArea {
                        // Universal geometry rule: if an AXWebArea is a left/navigation sidebar
                        // (narrower than 40% of the window width and positioned in the left half of the window),
                        // traverse top-to-bottom so pinned items, channels, and top conversations come first.
                        // If it is a main/right content pane, traverse bottom-up so the bottom input composer
                        // and newest messages are visited immediately before older scroll history.
                        if let rawPaneRect = copyFrame(element), let wf = primaryWindowFrame, wf.width > 200 {
                            let paneRect = (detectedZoomTransform != nil && isEnteringScaledSubtree)
                                ? detectedZoomTransform!.toScreen(rawPaneRect)
                                : rawPaneRect
                            let isLeftSidebar = paneRect.width < wf.width * 0.42 &&
                                (paneRect.center.x - wf.x) < wf.width * 0.45
                            if isLeftSidebar {
                                return false
                            }
                        }
                        return true
                    }
                    return reverseChildren
                }()
                if let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute as String) {
                    if effectiveReverseChildren && children.count >= 2 {
                        for child in children.prefix(100).reversed() {
                            traverse(
                                child,
                                depth: depth + 1,
                                branchDeadline: effectiveBranchDeadline,
                                branchMaxElements: effectiveBranchMaxElements,
                                reverseChildren: effectiveReverseChildren,
                                inScaledSubtree: isEnteringScaledSubtree
                            )
                        }
                    } else {
                        for child in children.prefix(120) {
                            traverse(
                                child,
                                depth: depth + 1,
                                branchDeadline: effectiveBranchDeadline,
                                branchMaxElements: effectiveBranchMaxElements,
                                reverseChildren: effectiveReverseChildren,
                                inScaledSubtree: isEnteringScaledSubtree
                            )
                        }
                    }
                }
            }
        }

        for root in roots.prefix(6) {
            let rootRole = copyStringAttribute(root, kAXRoleAttribute as String) ?? ""
            let rootIsFocusedDescendant = (rootRole != "AXWindow" && rootRole != "AXApplication" && rootRole != "AXMenuBar")
            traverse(
                root,
                depth: 0,
                branchDeadline: deadline,
                branchMaxElements: maxElements,
                reverseChildren: false,
                inScaledSubtree: rootIsFocusedDescendant && detectedZoomTransform != nil
            )
        }

        collected.sort { a, b in
            let rowA = Int(a.0.frame.y / 18.0)
            let rowB = Int(b.0.frame.y / 18.0)
            if rowA != rowB {
                return rowA < rowB
            }
            return a.0.frame.x < b.0.frame.x
        }

        var indexedElements: [UIElementRef] = []
        var newMap: [String: AXUIElement] = [:]
        for (idx, pair) in collected.enumerated() {
            let refId = "@e\(idx + 1)"
            var el = pair.0
            el.ref = refId
            indexedElements.append(el)
            newMap[refId] = pair.1
        }

        if updateLiveMap {
            lock.lock()
            liveElementMap = newMap
            if pid > 0 {
                liveElementMapByPid[pid] = newMap
            }
            lock.unlock()
        }

        return (appName, pid, resolvedWindowID, windowTitle, primaryWindowFrame, indexedElements, newMap)
    }

    public func updateLiveElementMap(_ map: [String: AXUIElement], pid: Int32? = nil) {
        lock.lock()
        liveElementMap = map
        if let p = pid, p > 0 {
            liveElementMapByPid[p] = map
        }
        lock.unlock()
    }

    private func normalizeRole(role: String, subrole: String?) -> String {
        if let sub = subrole, sub.hasPrefix("AX") && (sub.hasSuffix("Button") || sub.hasSuffix("Field")) {
            return String(sub.dropFirst(2)).lowercased()
        }
        if role.hasPrefix("AX") {
            return String(role.dropFirst(2)).lowercased()
        }
        return role.lowercased()
    }

    private func copyActionNames(_ element: AXUIElement) -> [String] {
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(element, &namesRef) == .success,
              let names = namesRef as? [String] else {
            return []
        }
        return names
    }

    private func extractLabel(from element: AXUIElement, depth: Int) -> String {
        let title = copyStringAttribute(element, kAXTitleAttribute as String)
        let desc = copyStringAttribute(element, kAXDescriptionAttribute as String)
        let val = copyValueAsString(element)
        if let direct = [title, desc, val].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) {
            return direct
        }
        let domClasses: [String] = copyAttribute(element, "AXDOMClassList") ?? []
        let lowerClasses = domClasses.map { $0.lowercased() }
        if lowerClasses.contains(where: { $0.contains("send-button") || $0.contains("submit-button") || $0.contains("btn-send") }) {
            return "发送"
        }
        if lowerClasses.contains(where: { $0.contains("schedule-button") }) {
            return "定时发送"
        }
        guard depth < 2,
              let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute as String) else {
            return ""
        }
        for child in children.prefix(6) {
            let childText = extractLabel(from: child, depth: depth + 1)
            if !childText.isEmpty {
                return childText
            }
        }
        return ""
    }

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let unwrapped = value else { return nil }
        return unwrapped as? T
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        if let str: String = copyAttribute(element, attribute) {
            return str
        }
        if let attrStr: NSAttributedString = copyAttribute(element, attribute) {
            return attrStr.string
        }
        return nil
    }

    private func copyBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let num = value as? NSNumber else { return nil }
        return num.boolValue
    }

    private func copyValueAsString(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success, let val = value else { return nil }
        if let str = val as? String {
            return str.count <= 4000 ? str : String(str.prefix(4000))
        }
        if let num = val as? NSNumber {
            return num.stringValue
        }
        return nil
    }

    private func copyFrame(_ element: AXUIElement) -> ScreenRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef,
              let sizeVal = sizeRef else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else {
            return nil
        }

        return ScreenRect(
            x: Double(point.x),
            y: Double(point.y),
            width: Double(size.width),
            height: Double(size.height)
        )
    }
}
