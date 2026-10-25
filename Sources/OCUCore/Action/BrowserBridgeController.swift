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
