import AppKit
import Foundation

struct LimitWindow {
    let key: String
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    var label: String {
        guard let windowMinutes else { return key }
        switch windowMinutes {
        case 300:
            return "5-hour usage"
        case 1_440:
            return "1-day usage"
        case 10_080:
            return "7-day usage"
        case 43_200...44_640:
            return "30-day usage"
        default:
            if windowMinutes % 1_440 == 0 {
                return "\(windowMinutes / 1_440)-day usage"
            }
            if windowMinutes % 60 == 0 {
                return "\(windowMinutes / 60)-hour usage"
            }
            return "\(windowMinutes)-minute usage"
        }
    }

    var identifier: String {
        "\(key):\(windowMinutes ?? -1)"
    }
}

struct QuotaSnapshot {
    let observedAt: Date?
    let sourcePath: String
    let windows: [LimitWindow]
    let planType: String?
    let limitId: String?
    let reachedType: String?

    var title: String {
        guard let firstWindow = windows.first else {
            return reachedType == nil ? "Codex --" : "Codex cap"
        }
        return "Codex \(Int(firstWindow.remainingPercent.rounded()))%"
    }

}

struct StatusRow {
    let percentText: String
    let rightText: String
    let fillPercent: Double
    let remainingPercent: Double
}

enum QuotaReadResult {
    case snapshot(QuotaSnapshot)
    case missing(String)
}

final class LoginItemManager {
    private let fileManager = FileManager.default
    private let label = "com.plutab.codex-quota-menubar"

    var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    var appBundleURL: URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL
        }

        var url = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return Bundle.main.bundleURL
    }

    var isEnabledForCurrentApp: Bool {
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let args = plist["ProgramArguments"] as? [String],
            !args.isEmpty
        else { return false }

        if args.count >= 2, args[0] == "/usr/bin/open" {
            return URL(fileURLWithPath: args[1]).standardizedFileURL == appBundleURL.standardizedFileURL
        }

        if let executable = Bundle.main.executableURL?.standardizedFileURL, args[0] == executable.path {
            return true
        }

        return false
    }

    @discardableResult
    func installOrUpdate() -> Bool {
        let launchAgents = plistURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [Bundle.main.executableURL?.path ?? CommandLine.arguments[0]],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            reloadLaunchAgent()
            return true
        } catch {
            NSLog("Failed to install login item: \(error)")
            return false
        }
    }

    @discardableResult
    func remove() -> Bool {
        unloadLaunchAgent()
        do {
            if fileManager.fileExists(atPath: plistURL.path) {
                try fileManager.removeItem(at: plistURL)
            }
            return true
        } catch {
            NSLog("Failed to remove login item: \(error)")
            return false
        }
    }

    private func reloadLaunchAgent() {
        unloadLaunchAgent()
        runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private func unloadLaunchAgent() {
        runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
    }

    private func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = nil
        process.standardError = nil
        try? process.run()
        process.waitUntilExit()
    }
}

final class CodexQuotaReader {
    private let fileManager = FileManager.default
    private let maxFilesToScan = 120
    private let tailBytes: UInt64 = 1_048_576

    func loadLatest() -> QuotaReadResult {
        let files = sessionFiles()
        if files.isEmpty {
            return .missing("No Codex session logs found.")
        }

        var bestSnapshot: QuotaSnapshot?

        for file in files.prefix(maxFilesToScan) {
            if let snapshot = latestSnapshot(in: file.url) {
                guard let observedAt = snapshot.observedAt else {
                    bestSnapshot = bestSnapshot ?? snapshot
                    continue
                }

                if let currentBest = bestSnapshot {
                    let bestDate = currentBest.observedAt ?? .distantPast
                    if observedAt > bestDate {
                        bestSnapshot = snapshot
                    }
                } else {
                    bestSnapshot = snapshot
                }
            }
        }

        if let bestSnapshot {
            return .snapshot(bestSnapshot)
        }

        return .missing("No rate limit event found in recent Codex logs.")
    }

    private func sessionFiles() -> [(url: URL, modifiedAt: Date)] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]

        var files: [(URL, Date)] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                    values.isRegularFile == true
                else { continue }

                files.append((url, values.contentModificationDate ?? .distantPast))
            }
        }

        return files.sorted { $0.1 > $1.1 }
    }

    private func latestSnapshot(in url: URL) -> QuotaSnapshot? {
        guard let text = readTail(url) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        for rawLine in lines.reversed() {
            guard rawLine.contains("\"token_count\""), rawLine.contains("\"rate_limits\"") else {
                continue
            }

            let line = String(rawLine)
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let payload = object["payload"] as? [String: Any],
                payload["type"] as? String == "token_count",
                let limits = payload["rate_limits"] as? [String: Any]
            else { continue }

            let snapshot = QuotaSnapshot(
                observedAt: parseDate(object["timestamp"] as? String),
                sourcePath: url.path,
                windows: parseWindows(limits),
                planType: stringValue(limits["plan_type"]),
                limitId: stringValue(limits["limit_id"]),
                reachedType: stringValue(limits["rate_limit_reached_type"])
            )

            if !snapshot.windows.isEmpty || snapshot.reachedType != nil {
                return snapshot
            }
        }

        return nil
    }

    private func readTail(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > tailBytes ? size - tailBytes : 0
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func parseWindows(_ limits: [String: Any]) -> [LimitWindow] {
        let windows = limits.compactMap { key, value in
            parseWindow(key: key, value: value)
        }
        return windows.sorted { lhs, rhs in
            let lhsMinutes = lhs.windowMinutes ?? Int.max
            let rhsMinutes = rhs.windowMinutes ?? Int.max
            if lhsMinutes == rhsMinutes {
                return lhs.key < rhs.key
            }
            return lhsMinutes < rhsMinutes
        }
    }

    private func parseWindow(key: String, value: Any?) -> LimitWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        guard let used = doubleValue(dict["used_percent"]) else { return nil }
        let windowMinutes = intValue(dict["window_minutes"])
        guard let windowMinutes, windowMinutes > 0 else { return nil }
        return LimitWindow(
            key: key,
            usedPercent: used,
            windowMinutes: windowMinutes,
            resetsAt: unixDate(dict["resets_at"])
        )
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private func unixDate(_ value: Any?) -> Date? {
        guard let seconds = doubleValue(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return String(describing: value)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 70)
    private let reader = CodexQuotaReader()
    private let loginItem = LoginItemManager()
    private var timer: Timer?
    private var lastResult: QuotaReadResult = .missing("Not loaded yet.")
    private var lastRefreshAt: Date?
    private let loginItemEnabledKey = "loginItemEnabled"
    private let selectedWindowIDsKey = "selectedWindowIDs"
    private lazy var codexLogo = loadCodexLogo()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureDefaultLoginItem()
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Codex quota monitor"
        rebuildMenu()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func refreshNow(_ sender: Any?) {
        refresh()
    }

    @objc private func openSessionsFolder(_ sender: Any?) {
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleStartAtLogin(_ sender: Any?) {
        let defaults = UserDefaults.standard
        if loginItem.isEnabledForCurrentApp {
            if loginItem.remove() {
                defaults.set(false, forKey: loginItemEnabledKey)
            }
        } else if loginItem.installOrUpdate() {
            defaults.set(true, forKey: loginItemEnabledKey)
        }
        rebuildMenu()
    }

    @objc private func toggleDisplayedWindow(_ sender: Any?) {
        guard
            let item = sender as? NSMenuItem,
            let identifier = item.representedObject as? String
        else { return }

        let defaults = UserDefaults.standard
        var selected = Set(defaults.stringArray(forKey: selectedWindowIDsKey) ?? [])
        if selected.contains(identifier) {
            selected.remove(identifier)
        } else {
            selected.insert(identifier)
        }
        defaults.set(Array(selected), forKey: selectedWindowIDsKey)
        refresh()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func configureDefaultLoginItem() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: loginItemEnabledKey) == nil {
            defaults.set(true, forKey: loginItemEnabledKey)
        }

        if defaults.bool(forKey: loginItemEnabledKey) {
            _ = loginItem.installOrUpdate()
        }
    }

    private func refresh() {
        lastRefreshAt = Date()
        lastResult = reader.loadLatest()
        switch lastResult {
        case .snapshot(let snapshot):
            let visible = visibleWindows(for: snapshot)
            if snapshot.windows.isEmpty {
                statusItem.length = 34
                statusItem.button?.image = placeholderStatusImage(text: "cap")
                statusItem.button?.toolTip = tooltip(for: snapshot)
            } else {
                statusItem.length = visible.isEmpty ? 18 : 70
                statusItem.button?.image = statusImage(for: snapshot)
                statusItem.button?.toolTip = tooltip(for: snapshot)
            }
        case .missing:
            statusItem.length = 70
            statusItem.button?.image = placeholderStatusImage()
            statusItem.button?.toolTip = "No Codex quota event found yet"
        }
        statusItem.button?.needsDisplay = true
        statusItem.button?.displayIfNeeded()
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        switch lastResult {
        case .snapshot(let snapshot):
            menu.addItem(disabled("Codex quota"))
            if let plan = snapshot.planType {
                menu.addItem(disabled("Plan: \(plan)"))
            }
            if let reached = snapshot.reachedType {
                menu.addItem(disabled("Limit reached: \(reached)"))
            }
            menu.addItem(.separator())

            if snapshot.windows.isEmpty, let reached = snapshot.reachedType {
                menu.addItem(disabled("State: \(reached)"))
            } else {
                for window in snapshot.windows {
                    menu.addItem(disabled("\(window.label): \(format(window: window))"))
                    if let reset = window.resetsAt {
                        menu.addItem(disabled("\(window.label) refill: \(format(date: reset))"))
                    }
                }
            }
            if let observed = snapshot.observedAt {
                menu.addItem(disabled("Quota updated: \(format(date: observed))"))
            }
            if let lastRefreshAt {
                menu.addItem(disabled("Checked: \(format(date: lastRefreshAt))"))
            }
            menu.addItem(disabled("Source: \(URL(fileURLWithPath: snapshot.sourcePath).lastPathComponent)"))

            if !snapshot.windows.isEmpty {
                menu.addItem(.separator())
                menu.addItem(disabled("Displayed windows"))
                let selected = selectedWindowIDs()
                for window in snapshot.windows {
                    let item = action(window.label, #selector(toggleDisplayedWindow(_:)))
                    item.representedObject = window.identifier
                    item.state = selected?.contains(window.identifier) ?? true ? .on : .off
                    menu.addItem(item)
                }
            }

        case .missing(let message):
            menu.addItem(disabled("Codex quota"))
            menu.addItem(.separator())
            menu.addItem(disabled(message))
            if let lastRefreshAt {
                menu.addItem(disabled("Checked: \(format(date: lastRefreshAt))"))
            }
        }

        menu.addItem(.separator())
        menu.addItem(action("Refresh now", #selector(refreshNow(_:))))
        menu.addItem(action("Open session logs", #selector(openSessionsFolder(_:))))
        menu.addItem(checkAction("Start at Login", #selector(toggleStartAtLogin(_:)), checked: loginItem.isEnabledForCurrentApp))
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit(_:))))

        statusItem.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func checkAction(_ title: String, _ selector: Selector, checked: Bool) -> NSMenuItem {
        let item = action(title, selector)
        item.state = checked ? .on : .off
        return item
    }

    private func tooltip(for snapshot: QuotaSnapshot) -> String {
        var parts: [String] = []
        for window in visibleWindows(for: snapshot) {
            parts.append("\(window.label) \(Int(window.remainingPercent.rounded()))% left")
        }
        if parts.isEmpty, let reached = snapshot.reachedType {
            parts.append(reached)
        }
        return parts.joined(separator: " / ")
    }

    private func statusImage(for snapshot: QuotaSnapshot) -> NSImage {
        let visibleWindows = visibleWindows(for: snapshot)
        if visibleWindows.isEmpty {
            return iconOnlyStatusImage()
        }

        let size = NSSize(width: 70, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        codexLogo.draw(in: NSRect(x: 0, y: 3.5, width: 15, height: 15))

        let barX: CGFloat = 20
        let barWidth: CGFloat = 50
        if visibleWindows.count == 1 {
            draw(
                row: makeStatusRow(for: visibleWindows.first),
                y: 6,
                barX: barX,
                barWidth: barWidth,
                rowHeight: 10,
                cornerRadius: 5
            )
        } else {
            let rows = [
                makeStatusRow(for: visibleWindows.first),
                makeStatusRow(for: visibleWindows[1])
            ]
            let rowHeight: CGFloat = 8
            let topY: CGFloat = 13
            let bottomY: CGFloat = 1.5
            draw(row: rows[0], y: topY, barX: barX, barWidth: barWidth, rowHeight: rowHeight, cornerRadius: 3)
            draw(row: rows[1], y: bottomY, barX: barX, barWidth: barWidth, rowHeight: rowHeight, cornerRadius: 3)
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func iconOnlyStatusImage() -> NSImage {
        let size = NSSize(width: 18, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        codexLogo.draw(in: NSRect(x: 0, y: 3.5, width: 15, height: 15))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func placeholderStatusImage(text: String = "--") -> NSImage {
        let size = NSSize(width: 70, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        codexLogo.draw(in: NSRect(x: 0, y: 3.5, width: 15, height: 15))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        text.draw(at: NSPoint(x: 16, y: 6), withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func selectedWindowIDs() -> Set<String>? {
        guard UserDefaults.standard.object(forKey: selectedWindowIDsKey) != nil else {
            return nil
        }
        return Set(UserDefaults.standard.stringArray(forKey: selectedWindowIDsKey) ?? [])
    }

    private func visibleWindows(for snapshot: QuotaSnapshot) -> [LimitWindow] {
        guard let selected = selectedWindowIDs() else {
            return Array(snapshot.windows.prefix(2))
        }
        let filtered = snapshot.windows.filter { selected.contains($0.identifier) }
        return Array(filtered.prefix(2))
    }

    private func makeStatusRow(for window: LimitWindow?) -> StatusRow {
        guard let window else {
            return StatusRow(percentText: "--", rightText: "--", fillPercent: 0, remainingPercent: 0)
        }

        let percent = Int(window.remainingPercent.rounded())
        let rightText: String
        if let reset = window.resetsAt {
            rightText = relative(reset)
        } else {
            rightText = "--"
        }
        return StatusRow(
            percentText: "\(percent)%",
            rightText: rightText,
            fillPercent: window.remainingPercent,
            remainingPercent: window.remainingPercent
        )
    }

    private func draw(row: StatusRow, y: CGFloat, barX: CGFloat, barWidth: CGFloat, rowHeight: CGFloat, cornerRadius: CGFloat) {
        let barRect = NSRect(x: barX, y: y, width: barWidth, height: rowHeight)
        let backgroundPath = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(calibratedWhite: 0.0, alpha: 0.42).setFill()
        backgroundPath.fill()

        let fillWidth = max(0, min(barWidth, barWidth * CGFloat(row.fillPercent / 100)))
        let fillRect = NSRect(x: barX, y: y, width: fillWidth, height: rowHeight)
        if fillWidth > 0 {
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius)
            color(forRemaining: row.remainingPercent).setFill()
            fillPath.fill()
        }

        let leftAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7.5, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.5, alpha: 1.0),
            .kern: -0.2
        ]
        let rightAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7.5, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.5, alpha: 1.0),
            .kern: -0.2
        ]

        let leftText = NSAttributedString(string: row.percentText, attributes: leftAttributes)
        let rightText = NSAttributedString(string: row.rightText, attributes: rightAttributes)
        let leftSize = leftText.size()
        let rightSize = rightText.size()
        let leftTextY = y + ((rowHeight - leftSize.height) / 2) - 0.5
        let rightTextY = y + ((rowHeight - rightSize.height) / 2) - 0.5
        let leftOrigin = NSPoint(x: barX + 0.25, y: leftTextY)
        let rightOrigin = NSPoint(x: barX + barWidth - rightSize.width - 0.25, y: rightTextY)

        drawText(leftText, at: leftOrigin, fillRect: fillRect, barRect: barRect)
        drawText(rightText, at: rightOrigin, fillRect: fillRect, barRect: barRect)
    }

    private func drawText(
        _ text: NSAttributedString,
        at origin: NSPoint,
        fillRect: NSRect,
        barRect: NSRect
    ) {
        let textSize = text.size()
        let textRect = NSRect(origin: origin, size: textSize)

        if let context = NSGraphicsContext.current?.cgContext, fillRect.width > 0 {
            context.saveGState()
            context.clip(to: fillRect)
            NSGraphicsContext.current?.compositingOperation = .clear
            text.draw(at: origin)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            context.restoreGState()
        }

        let remainingStartX = max(fillRect.maxX, barRect.minX)
        let remainingRect = NSRect(
            x: remainingStartX,
            y: barRect.minY,
            width: max(0, barRect.maxX - remainingStartX),
            height: barRect.height
        )

        if remainingRect.width > 0, remainingRect.intersects(textRect),
           let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.clip(to: remainingRect)
            text.draw(at: origin)
            context.restoreGState()
        }
    }

    private func loadCodexLogo() -> NSImage {
        if let bundledPath = Bundle.main.path(forResource: "codex", ofType: "png"),
           let image = NSImage(contentsOfFile: bundledPath) {
            return image
        }

        let fallbackPath = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("codex.png")
            .path
        return NSImage(contentsOfFile: fallbackPath) ?? NSImage(size: .zero)
    }

    private func color(forRemaining remainingPercent: Double) -> NSColor {
        switch remainingPercent {
        case 40...100:
            return NSColor.systemGreen
        case 20..<40:
            return NSColor.systemYellow
        default:
            return NSColor.systemRed
        }
    }

    private func format(window: LimitWindow) -> String {
        let used = Int(window.usedPercent.rounded())
        let remaining = Int(window.remainingPercent.rounded())
        var text = "\(used)% used / \(remaining)% left"
        if let reset = window.resetsAt {
            text += ", reset in \(relative(reset))"
        }
        return text
    }

    private func relative(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow.rounded())
        if seconds <= 0 { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(max(1, minutes))m"
    }

    private func format(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

func renderOnce(_ result: QuotaReadResult) -> String {
    switch result {
    case .missing(let message):
        return "Codex --\n\(message)"
    case .snapshot(let snapshot):
        var lines = [snapshot.title]
        for window in snapshot.windows {
            lines.append("\(window.label): \(Int(window.usedPercent.rounded()))% used / \(Int(window.remainingPercent.rounded()))% left")
            if let reset = window.resetsAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .medium
                lines.append("\(window.label) refill: \(formatter.string(from: reset))")
            }
        }
        if snapshot.windows.isEmpty, let reached = snapshot.reachedType {
            lines.append("State: \(reached)")
        }
        if let plan = snapshot.planType {
            lines.append("Plan: \(plan)")
        }
        lines.append("Source: \(snapshot.sourcePath)")
        return lines.joined(separator: "\n")
    }
}

let args = CommandLine.arguments.dropFirst()
if args.contains("--once") {
    print(renderOnce(CodexQuotaReader().loadLatest()))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

