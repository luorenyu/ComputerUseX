import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

public final class AXScanner: @unchecked Sendable {
    public static let shared = AXScanner()

    private typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private let lock = NSLock()
    private var liveElementMap: [String: AXUIElement] = [:]
    private let getWindowIDFn: AXUIElementGetWindowFn?

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
    }

    public func cgWindowID(for axWindow: AXUIElement) -> UInt32? {
        guard let fn = getWindowIDFn else { return nil }
        var wid: CGWindowID = 0
        if fn(axWindow, &wid) == .success, wid > 0 {
            return wid
        }
        return nil
    }

    public func resolveLiveAXElement(for ref: String) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return liveElementMap[ref]
    }

    public func performNativePress(ref: String) -> Bool {
        guard let element = resolveLiveAXElement(for: ref) else {
            return false
        }
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return err == .success
    }

    /// Sets `kAXValueAttribute` directly on an AX text field / search field in the background without stealing OS focus,
    /// and performs read-back verification so silent no-ops (e.g. `<input type="date">` or custom React inputs)
    /// return `false` and automatically trigger synthesized keyboard typing fallback.
    public func performNativeSetValue(ref: String, value: String, submit: Bool = false) -> Bool {
        guard let element = resolveLiveAXElement(for: ref) else {
            return false
        }
        let beforeVal = copyValueAsString(element)?.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard err == .success else { return false }

        let expected = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var verified = false
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.03)
            if let afterVal = copyValueAsString(element)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if afterVal == expected || (afterVal != beforeVal && !afterVal.isEmpty) {
                    verified = true
                    break
                }
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
        maxDepth: Int = 16,
        maxElements: Int = 220
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

        // Enable accessibility tree generation for Electron / Chromium / Qt / WeChat apps
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let desktopBounds = PermissionManager.shared.desktopBounds()
        var resolvedWindowID: UInt32? = nil
        var windowTitle: String? = nil
        var primaryWindowFrame: ScreenRect? = nil
        var roots: [AXUIElement] = []

        let allWindows: [AXUIElement] = copyAttribute(axApp, kAXWindowsAttribute as String) ?? []
        let visibleWindows = allWindows.filter { win in
            let isMin: Bool = copyAttribute(win, kAXMinimizedAttribute as String) ?? false
            return !isMin
        }

        let targetWinID = preferredWindowID ?? SyntheticFocusEnforcer.shared.pinnedWindowID(forPid: pid)

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
                // Target window ID was explicitly specified (or pinned), e.g., WeChat's content window #499
                resolvedWindowID = desiredWid
                roots.append(contentsOf: visibleWindows.isEmpty ? allWindows : visibleWindows)
            }
        } else if let focusedWindow: AXUIElement = copyAttribute(axApp, kAXFocusedWindowAttribute as String),
           (copyAttribute(focusedWindow, kAXMinimizedAttribute as String) as Bool? ?? false) == false {
            resolvedWindowID = cgWindowID(for: focusedWindow)
            windowTitle = copyStringAttribute(focusedWindow, kAXTitleAttribute as String)
            primaryWindowFrame = copyFrame(focusedWindow)
            roots.append(focusedWindow)
        } else if let mainWindow: AXUIElement = copyAttribute(axApp, kAXMainWindowAttribute as String),
                  (copyAttribute(mainWindow, kAXMinimizedAttribute as String) as Bool? ?? false) == false {
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

        if roots.isEmpty {
            roots.append(axApp)
            if let menuBar: AXUIElement = copyAttribute(axApp, kAXMenuBarAttribute as String) {
                roots.append(menuBar)
            }
        }

        var collected: [(UIElementRef, AXUIElement)] = []
        var visitedHashes = Set<CFHashCode>()
        let deadline = Date().addingTimeInterval(1.8)

        func traverse(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth,
                  collected.count < maxElements,
                  Date() < deadline else {
                return
            }

            let hash = CFHash(element)
            if visitedHashes.contains(hash) { return }
            visitedHashes.insert(hash)

            let role = copyStringAttribute(element, kAXRoleAttribute as String) ?? "AXUnknown"
            let subrole = copyStringAttribute(element, kAXSubroleAttribute as String)
            let title = copyStringAttribute(element, kAXTitleAttribute as String)
            let desc = copyStringAttribute(element, kAXDescriptionAttribute as String)
            let help = copyStringAttribute(element, kAXHelpAttribute as String)
            let placeholder = copyStringAttribute(element, kAXPlaceholderValueAttribute as String)
            let valueStr = copyValueAsString(element)
            let enabled = copyBoolAttribute(element, kAXEnabledAttribute as String) ?? true
            let focused = copyBoolAttribute(element, kAXFocusedAttribute as String) ?? false

            if let rect = copyFrame(element) {
                let isOnScreen = rect.width >= 6 && rect.height >= 6 &&
                    rect.intersectionArea(with: desktopBounds) > 0 &&
                    rect.width <= desktopBounds.width * 0.98 &&
                    rect.height <= desktopBounds.height * 0.98

                if isOnScreen {
                    let displayLabel = [title, desc, placeholder, valueStr, help]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first(where: { !$0.isEmpty }) ?? ""

                    let isInteractive = interactiveRoles.contains(role) ||
                        subrole == "AXCloseButton" ||
                        subrole == "AXMinimizeButton" ||
                        subrole == "AXZoomButton" ||
                        subrole == "AXSearchField"

                    let isMeaningfulText = (role == "AXStaticText" && !displayLabel.isEmpty && displayLabel.count <= 120)

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

            if containerRolesToTraverse.contains(role) || depth < 6 {
                if let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute as String) {
                    for child in children.prefix(100) {
                        traverse(child, depth: depth + 1)
                    }
                }
            }
        }

        for root in roots.prefix(5) {
            traverse(root, depth: 0)
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

        lock.lock()
        liveElementMap = newMap
        lock.unlock()

        return (appName, pid, resolvedWindowID, windowTitle, primaryWindowFrame, indexedElements, newMap)
    }

    public func updateLiveElementMap(_ map: [String: AXUIElement]) {
        lock.lock()
        liveElementMap = map
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
            return str.count <= 200 ? str : String(str.prefix(200))
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
