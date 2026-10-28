import Foundation
import AppKit

public struct BrowserTabInfo: Codable, Equatable, Sendable {
    public var browser: String
    public var windowIndex: Int
    public var tabIndex: Int
    public var title: String
    public var url: String
    public var isActive: Bool

    public init(
        browser: String,
        windowIndex: Int,
        tabIndex: Int,
        title: String,
        url: String,
        isActive: Bool
    ) {
        self.browser = browser
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.title = title
        self.url = url
        self.isActive = isActive
    }
}

/// Hybrid AX + Browser DOM / CDP / AppleScript JavaScript Bridge (`ocu browser`).
/// Enables zero-focus background tab enumeration, URL navigation, DOM element inspection,
/// CSS selector clicking, and JavaScript evaluation across Chromium browsers (Google Chrome, Arc,
/// Microsoft Edge, Brave Browser) and Safari without stealing user foreground focus.
public final class BrowserBridgeController: @unchecked Sendable {
    public static let shared = BrowserBridgeController()

    public static let supportedChromiumBrowsers: [String] = [
        "Google Chrome",
        "Arc",
        "Microsoft Edge",
        "Brave Browser",
        "Chromium"
    ]

    private init() {}

    /// Returns true if the target application name or PID corresponds to a supported Chromium or Safari browser.
    public func isBrowserApp(_ appName: String? = nil, pid: Int32? = nil) -> Bool {
        let resolvedName: String = {
            if let name = appName, !name.isEmpty { return name }
            if let p = pid, p > 0, let running = NSRunningApplication(processIdentifier: p) {
                return running.localizedName ?? running.bundleIdentifier ?? ""
            }
            return ""
        }().lowercased()
        guard !resolvedName.isEmpty else { return false }
        let keywords = ["chrome", "safari", "arc", "edge", "brave", "chromium"]
        return keywords.contains { resolvedName.contains($0) }
    }

    /// Zero-focus DOM fallback click at a screen coordinate `(point.x, point.y)` or matching text label inside a browser window.
    public func clickAtScreenPointOrLabel(
        point: ScreenPoint,
        windowBounds: ScreenRect,
        label: String? = nil,
        browser: String? = nil
    ) -> String? {
        guard windowBounds.width > 80, windowBounds.height > 80 else { return nil }
        let relX = max(0.0, min(1.0, (point.x - windowBounds.x) / windowBounds.width))
        let distFromBottom = max(0.0, windowBounds.maxY - point.y)
        let safeLabel = (label ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let js = """
        (function() {
            var vx = Math.round(window.innerWidth * \(String(format: "%.5f", relX)));
            var vy = Math.round(window.innerHeight - \(String(format: "%.1f", distFromBottom)));
            var el = (vx >= 0 && vy >= 0 && vx <= window.innerWidth && vy <= window.innerHeight) ? document.elementFromPoint(vx, vy) : null;
            var lbl = '\(safeLabel)';
            if (lbl.length > 0 && (!el || (el.innerText || el.value || '').indexOf(lbl) === -1)) {
                var cands = Array.from(document.querySelectorAll('button,a,input,[role="button"],[role="tab"],[role="menuitem"],span,div'));
                var best = null;
                var bestDist = 999999;
                for (var i = 0; i < cands.length; i++) {
                    var n = cands[i];
                    var txt = (n.innerText || n.value || n.getAttribute('aria-label') || '').trim();
                    if (txt === lbl || (txt.length <= lbl.length + 12 && txt.indexOf(lbl) !== -1)) {
                        var r = n.getBoundingClientRect();
                        if (r.width > 4 && r.height > 4) {
                            var d = Math.hypot((r.left + r.width/2) - vx, (r.top + r.height/2) - vy);
                            if (d < bestDist) { bestDist = d; best = n; }
                        }
                    }
                }
                if (best && bestDist < 260) { el = best; }
            }
            if (!el) return '';
            if (el.focus) el.focus();
            var opts = {bubbles: true, cancelable: true, view: window, clientX: vx, clientY: vy};
            el.dispatchEvent(new MouseEvent('mousedown', opts));
            el.dispatchEvent(new MouseEvent('mouseup', opts));
            el.click();
            return (el.tagName || 'EL') + ':' + ((el.innerText || el.value || '').trim().slice(0, 32));
        })()
        """
        if let outcome = try? evaluateJavaScript(js, browser: browser),
           let details = outcome.details,
           !details.isEmpty && details != "(undefined)" {
            return details
        }
        return nil
    }

    /// Zero-focus DOM text injection at a screen coordinate `(point.x, point.y)` or into `document.activeElement` in a browser.
    public func typeAtScreenPoint(
        text: String,
        point: ScreenPoint?,
        windowBounds: ScreenRect?,
        clearFirst: Bool,
        submit: Bool,
        browser: String? = nil
    ) -> Bool {
        let safeText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
        var relX = -1.0
        var distFromBottom = -1.0
        if let pt = point, let wb = windowBounds, wb.width > 80, wb.height > 80 {
            relX = max(0.0, min(1.0, (pt.x - wb.x) / wb.width))
            distFromBottom = max(0.0, wb.maxY - pt.y)
        }
        let js = """
        (function() {
            var el = null;
            if (\(relX >= 0 ? "true" : "false")) {
                var vx = Math.round(window.innerWidth * \(String(format: "%.5f", max(0, relX))));
                var vy = Math.round(window.innerHeight - \(String(format: "%.1f", max(0, distFromBottom))));
                var hit = document.elementFromPoint(vx, vy);
                while (hit && hit !== document.body) {
                    var tag = (hit.tagName || '').toLowerCase();
                    if (tag === 'textarea' || tag === 'input' || hit.isContentEditable || hit.getAttribute('contenteditable') === 'true') {
                        el = hit; break;
                    }
                    hit = hit.parentElement;
                }
            }
            if (!el) {
                var act = document.activeElement;
                if (act && act !== document.body) el = act;
            }
            if (!el) {
                el = document.querySelector('textarea:not([disabled]), input[type="text"]:not([disabled]), [contenteditable="true"]');
            }
            if (!el) return 'ERR_NO_INPUT';
            el.focus();
            var val = '\(safeText)';
            var tag = (el.tagName || '').toLowerCase();
            if (tag === 'textarea' || tag === 'input') {
                var proto = tag === 'textarea' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
                var setter = Object.getOwnPropertyDescriptor(proto, 'value');
                var nextVal = \(clearFirst ? "val" : "(el.value || '') + val");
                if (setter && setter.set) { setter.set.call(el, nextVal); } else { el.value = nextVal; }
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
            } else {
                if (\(clearFirst ? "true" : "false")) { document.execCommand('selectAll', false, null); }
                document.execCommand('insertText', false, val);
            }
            if (\(submit ? "true" : "false")) {
                el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true}));
                if (el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
            }
            return 'OK_TYPED';
        })()
        """
        if let outcome = try? evaluateJavaScript(js, browser: browser),
           let details = outcome.details,
           details.contains("OK_TYPED") {
            return true
        }
        return false
    }

    /// Zero-focus DOM scroll at a screen coordinate `(point.x, point.y)` inside a browser window (supports inner scrollable containers).
    @discardableResult
    public func scrollAtScreenPoint(
        dx: Double,
        dy: Double,
        point: ScreenPoint,
        windowBounds: ScreenRect,
        browser: String? = nil
    ) -> Bool {
        guard windowBounds.width > 80, windowBounds.height > 80 else { return false }
        let relX = max(0.0, min(1.0, (point.x - windowBounds.x) / windowBounds.width))
        let distFromBottom = max(0.0, windowBounds.maxY - point.y)
        // In macOS CGEvent scroll wheel convention used by `cux scroll`, negative `dy` (e.g. -240, -1000) scrolls DOWN
        // (increasing DOM `scrollTop`), whereas positive `dy` scrolls UP (decreasing DOM `scrollTop`).
        let domDeltaY = Int((-dy).rounded())
        let domDeltaX = Int((-dx).rounded())
        let js = """
        (function() {
            var vx = Math.round(window.innerWidth * \(String(format: "%.5f", relX)));
            var vy = Math.round(window.innerHeight - \(String(format: "%.1f", distFromBottom)));
            var el = document.elementFromPoint(vx, vy);
            var target = null;
            while (el && el !== document.body && el !== document.documentElement) {
                var st = window.getComputedStyle(el);
                var oy = st ? st.overflowY : '';
                if ((oy === 'auto' || oy === 'scroll' || oy === 'overlay') && el.scrollHeight > el.clientHeight + 4) {
                    target = el; break;
                }
                el = el.parentElement;
            }
            var deltaY = \(domDeltaY);
            var deltaX = \(domDeltaX);
            if (target) {
                var beforeTop = target.scrollTop;
                target.scrollBy({left: deltaX, top: deltaY, behavior: 'instant'});
                if (target.scrollTop !== beforeTop) return 'SCROLLED_EL';
            }
            var beforeWinY = window.scrollY;
            window.scrollBy({left: deltaX, top: deltaY, behavior: 'instant'});
            if (window.scrollY !== beforeWinY) return 'SCROLLED_WIN';
            var all = document.querySelectorAll('div, main, section, article, ul');
            var best = null;
            var bestArea = 0;
            for (var i = 0; i < all.length; i++) {
                var c = all[i];
                if (c.scrollHeight > c.clientHeight + 16 && c.clientWidth > 180 && c.clientHeight > 120) {
                    var cst = window.getComputedStyle(c);
                    var coy = cst ? cst.overflowY : '';
                    if (coy === 'auto' || coy === 'scroll' || coy === 'overlay') {
                        var area = c.clientWidth * c.clientHeight;
                        if (area > bestArea) { bestArea = area; best = c; }
                    }
                }
            }
            if (best) {
                best.scrollBy({left: deltaX, top: deltaY, behavior: 'instant'});
                return 'SCROLLED_SPA_CONTAINER';
            }
            return 'SCROLLED_WIN';
        })()
        """
        if let outcome = try? evaluateJavaScript(js, browser: browser),
           let details = outcome.details,
           details.contains("SCROLLED_") {
            return true
        }
        return false
    }

    /// Resolves the target running browser application name (defaults to Google Chrome or Safari if running).
    public func resolveBrowserAppName(preferred: String? = nil) -> String {
        if let pref = preferred, !pref.isEmpty {
            let lower = pref.lowercased()
            if lower == "chrome" { return "Google Chrome" }
            if lower == "edge" { return "Microsoft Edge" }
            if lower == "brave" { return "Brave Browser" }
            if lower == "arc" { return "Arc" }
            if lower == "safari" { return "Safari" }
            return pref
        }

        let runningNames = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName })
        for candidate in Self.supportedChromiumBrowsers + ["Safari"] {
            if runningNames.contains(candidate) {
                return candidate
            }
        }
        return "Google Chrome"
    }

    /// Lists open tabs across windows in the target browser without bringing the browser to the foreground.
    public func listTabs(browser: String? = nil) throws -> [BrowserTabInfo] {
        let appName = resolveBrowserAppName(preferred: browser)
        let isSafari = appName.lowercased().contains("safari")

        let scriptSource: String
        if isSafari {
            scriptSource = """
            set output to ""
            tell application "Safari"
                set winIdx to 1
                repeat with w in windows
                    set tabIdx to 1
                    set curTab to current tab of w
                    repeat with t in tabs of w
                        set isAct to (t is curTab)
                        set output to output & winIdx & "\t" & tabIdx & "\t" & isAct & "\t" & (name of t) & "\t" & (URL of t) & "\n"
                        set tabIdx to tabIdx + 1
                    end repeat
                    set winIdx to winIdx + 1
                end repeat
            end tell
            return output
            """
        } else {
            scriptSource = """
            set output to ""
            tell application "\(appName)"
                set winIdx to 1
                repeat with w in windows
                    set tabIdx to 1
                    set activeIdx to active tab index of w
                    repeat with t in tabs of w
                        set isAct to (tabIdx is equal to activeIdx)
                        set output to output & winIdx & "\t" & tabIdx & "\t" & isAct & "\t" & (title of t) & "\t" & (URL of t) & "\n"
                        set tabIdx to tabIdx + 1
                    end repeat
                    set winIdx to winIdx + 1
                end repeat
            end tell
            return output
            """
        }

        let raw = try runAppleScript(scriptSource)
        var tabs: [BrowserTabInfo] = []
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { continue }
            let wIdx = Int(parts[0]) ?? 1
            let tIdx = Int(parts[1]) ?? 1
            let active = parts[2].lowercased() == "true"
            let title = parts[3]
            let url = parts[4]
            tabs.append(BrowserTabInfo(
                browser: appName,
                windowIndex: wIdx,
                tabIndex: tIdx,
                title: title,
                url: url,
                isActive: active
            ))
        }
        return tabs
    }

    /// Navigates the active tab (or opens a new tab) to a URL in the background without stealing focus.
    public func navigateURL(_ urlString: String, browser: String? = nil, newTab: Bool = false) throws -> ActionOutcome {
        let start = Date()
        let appName = resolveBrowserAppName(preferred: browser)
        let escapedURL = urlString.replacingOccurrences(of: "\"", with: "\\\"")
        let isSafari = appName.lowercased().contains("safari")

        let script: String
        if isSafari {
            if newTab {
                script = """
                tell application "Safari"
                    if (count of windows) is 0 then make new document with properties {URL:"\(escapedURL)"}
                    tell front window
                        set current tab to (make new tab with properties {URL:"\(escapedURL)"})
                    end tell
                end tell
                """
            } else {
                script = """
                tell application "Safari"
                    if (count of windows) is 0 then
                        make new document with properties {URL:"\(escapedURL)"}
                    else
                        set URL of current tab of front window to "\(escapedURL)"
                    end if
                end tell
                """
            }
        } else {
            if newTab {
                script = """
                tell application "\(appName)"
                    if (count of windows) is 0 then
                        make new window
                    end if
                    tell front window
                        make new tab with properties {URL:"\(escapedURL)"}
                    end tell
                end tell
                """
            } else {
                script = """
                tell application "\(appName)"
                    if (count of windows) is 0 then
                        make new window
                    end if
                    set URL of active tab of front window to "\(escapedURL)"
                end tell
                """
            }
        }

        _ = try runAppleScript(script)
        return ActionOutcome(
            action: "browser_navigate",
            targetDescription: "\(appName) -> \(urlString)",
            details: "background navigation (\(newTab ? "new tab" : "active tab"))",
            elapsedMs: Int(Date().timeIntervalSince(start) * 1000)
        )
    }

    /// Evaluates JavaScript in the target browser's active tab (or tab matching a URL/title substring) in the background.
    public func evaluateJavaScript(
        _ jsCode: String,
        browser: String? = nil,
        tabFilter: String? = nil
    ) throws -> ActionOutcome {
        let start = Date()
        let appName = resolveBrowserAppName(preferred: browser)
        let escapedJS = jsCode
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")

        let isSafari = appName.lowercased().contains("safari")
        let script: String
        if isSafari {
            script = """
            tell application "Safari"
                return do JavaScript "\(escapedJS)" in current tab of front window
            end tell
            """
        } else if let filter = tabFilter, !filter.isEmpty {
            let escapedFilter = filter.replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "\(appName)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (title of t contains "\(escapedFilter)") or (URL of t contains "\(escapedFilter)") then
                            return execute t javascript "\(escapedJS)"
                        end if
                    end repeat
                end repeat
                return execute active tab of front window javascript "\(escapedJS)"
            end tell
            """
        } else {
            script = """
            tell application "\(appName)"
                return execute active tab of front window javascript "\(escapedJS)"
            end tell
            """
        }

        let result = try runAppleScript(script)
        return ActionOutcome(
            action: "browser_eval",
            targetDescription: "\(appName) JS Evaluation",
            details: result.isEmpty ? "(undefined)" : result,
            elapsedMs: Int(Date().timeIntervalSince(start) * 1000)
        )
    }

    /// Clicks a DOM element by CSS selector or text content directly inside the browser's DOM in the background.
    public func clickDOMSelector(_ selectorOrText: String, browser: String? = nil, tabFilter: String? = nil) throws -> ActionOutcome {
        let safeQuery = selectorOrText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var el = document.querySelector('\(safeQuery)');
            if (!el) {
                var nodes = Array.from(document.querySelectorAll('a,button,input,[role="button"],span,div'));
                el = nodes.find(function(n) { return (n.innerText || n.value || '').trim().indexOf('\(safeQuery)') !== -1; });
            }
            if (!el) return 'ERR_DOM_NOT_FOUND: ' + '\(safeQuery)';
            el.scrollIntoView({block: 'center', inline: 'center'});
            el.click();
            return 'CLICKED_DOM: <' + el.tagName.toLowerCase() + '> ' + (el.innerText || el.value || el.id || '').slice(0, 48).trim();
        })()
        """
        return try evaluateJavaScript(js, browser: browser, tabFilter: tabFilter)
    }

    /// Extracts interactive DOM elements from the active tab via JS injection (zero-focus DOM snapshot).
    public func extractDOMSummary(browser: String? = nil, tabFilter: String? = nil) throws -> ActionOutcome {
        let js = """
        (function() {
            var items = Array.from(document.querySelectorAll('a[href],button,input,textarea,select,[role="button"]')).slice(0, 60);
            var lines = items.map(function(el, idx) {
                var r = el.getBoundingClientRect();
                var tag = el.tagName.toLowerCase();
                var txt = (el.innerText || el.placeholder || el.value || el.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim().slice(0, 40);
                var sel = el.id ? ('#' + el.id) : (el.name ? (tag + '[name="' + el.name + '"]') : tag);
                return '@dom' + (idx + 1) + '|' + sel + '|' + Math.round(r.left + r.width/2) + ',' + Math.round(r.top + r.height/2) + '|' + txt;
            });
            return 'Title: ' + document.title + ' | URL: ' + location.href + '\\n' + lines.join('\\n');
        })()
        """
        return try evaluateJavaScript(js, browser: browser, tabFilter: tabFilter)
    }

    private func runAppleScript(_ source: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = (String(data: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let errStr = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if proc.terminationStatus != 0 {
            let hint: String
            if errStr.localizedCaseInsensitiveContains("JavaScript from Apple Events") {
                hint = "In Chrome/Safari menu bar, enable 'View > Developer > Allow JavaScript from Apple Events'."
            } else {
                hint = "Ensure the browser is running and Automation permission is granted."
            }
            throw OCUError(
                code: .actionFailed,
                message: "Browser bridge AppleScript failed: \(errStr)",
                recoveryHint: hint
            )
        }
        return outStr
    }
}
