import SwiftUI
import Combine

// MARK: - App Entry Point
@main
struct AIIARcloneSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: quit if another instance is already running
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.rclone.sync-mac.app"
        )
        let otherInstances = runningApps.filter { $0.processIdentifier != currentPID }
        if !otherInstances.isEmpty {
            // Another instance is already running — activate it and quit this one
            otherInstances.first?.activate()
            NSApp.terminate(nil)
            return
        }

        statusBarController = StatusBarController()
        // Hide from dock
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Sync Status Model

/// Per-remote status (from status-{remote}.json)
struct RemoteStatus: Codable {
    var status: String       // syncing, success, error
    var message: String
    let remote: String?
    let timestamp: String
    let timestampLocal: String
    let filesTransferred: Int
    let errors: Int
    let dryRun: Bool
    let pid: Int

    enum CodingKeys: String, CodingKey {
        case status, message, remote, timestamp, errors, pid
        case timestampLocal = "timestamp_local"
        case filesTransferred = "files_transferred"
        case dryRun = "dry_run"
    }
}

/// Legacy combined status (for backward compat during transition)
struct RemoteResult: Codable {
    let remote: String
    let result: String    // success / error
    let message: String
}

// MARK: - Sync Rules Manager
class SyncRulesManager {
    static let shared = SyncRulesManager()

    struct SyncRules: Codable {
        var mode: String  // "auto" or "manual"
        var rules: [String: [String]]  // directory -> [remotes]

        static var defaultRules: SyncRules {
            SyncRules(mode: "auto", rules: [:])
        }
    }

    private let rulesPath: String
    var rules: SyncRules

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        rulesPath = "\(home)/.local/share/rclone-sync-mac/sync-rules.json"
        rules = SyncRules.defaultRules
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: rulesPath)),
              let loaded = try? JSONDecoder().decode(SyncRules.self, from: data) else {
            return
        }
        rules = loaded
    }

    func save() {
        let dir = (rulesPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(rules) {
            // Pretty print
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try? pretty.write(to: URL(fileURLWithPath: rulesPath))
            } else {
                try? data.write(to: URL(fileURLWithPath: rulesPath))
            }
        }
    }

    /// Get the list of first-level subdirectories in LOCAL_PATH
    func listLocalSubdirs(localPath: String) -> [String] {
        let expanded = localPath.replacingOccurrences(of: "$HOME",
            with: FileManager.default.homeDirectoryForCurrentUser.path)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: expanded) else { return [] }
        return items.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            let fullPath = "\(expanded)/\(name)"
            // Follow symlinks
            return FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    /// Check if a directory should sync to a given remote
    func shouldSync(dir: String, remote: String, allRemotes: [String]) -> Bool {
        if rules.mode == "auto" {
            // Auto mode: sync everything unless explicitly restricted
            if let allowedRemotes = rules.rules[dir] {
                return allowedRemotes.contains(remote)
            }
            return true  // Not in rules = sync to all
        } else {
            // Manual mode: only sync if explicitly listed
            if let allowedRemotes = rules.rules[dir] {
                return allowedRemotes.contains(remote)
            }
            return false  // Not in rules = don't sync
        }
    }

    /// Generate exclude filters for a specific remote
    func excludeFilters(for remote: String, dirs: [String], allRemotes: [String]) -> [String] {
        var excludes: [String] = []
        for dir in dirs {
            if !shouldSync(dir: dir, remote: remote, allRemotes: allRemotes) {
                excludes.append("- \(dir)/**")
            }
        }
        return excludes
    }

    /// Check if rules file exists
    var hasRules: Bool {
        FileManager.default.fileExists(atPath: rulesPath)
    }
}

// MARK: - Sync Rules Window
class SyncRulesWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var checkboxes: [[NSButton]] = []  // [row][col]
    private var modeControl: NSSegmentedControl!
    private var dirs: [String] = []
    private var remotes: [String] = []
    private let rulesManager = SyncRulesManager.shared
    private var config: SyncConfig
    private var onSave: (() -> Void)?

    private let displayMap: [String: String] = [
        "onedrive": "\u{2601}\u{FE0F} OneDrive", "gdrive": "\u{1F4C1} G.Drive", "drive": "\u{1F4C1} G.Drive",
        "dropbox": "\u{1F4E6} Dropbox", "s3": "\u{1FAA3} S3", "webdav": "\u{1F310} WebDAV", "sftp": "\u{1F5A5}\u{FE0F} SFTP"
    ]

    init(config: SyncConfig, onSave: (() -> Void)? = nil) {
        self.config = config
        self.onSave = onSave
        super.init()
    }

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Get data
        let localPath = config.localPath.isEmpty ? "\(FileManager.default.homeDirectoryForCurrentUser.path)/CloudSync" : config.localPath
        dirs = rulesManager.listLocalSubdirs(localPath: localPath)
        remotes = config.activeRemotes

        guard !dirs.isEmpty && !remotes.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "\u{26A0}\u{FE0F} \u{65E0}\u{6CD5}\u{914D}\u{7F6E}"
            alert.informativeText = dirs.isEmpty
                ? "\u{540C}\u{6B65}\u{76EE}\u{5F55}\u{4E0B}\u{6CA1}\u{6709}\u{5B50}\u{76EE}\u{5F55}\u{FF1A}\(localPath)"
                : "\u{672A}\u{914D}\u{7F6E}\u{4EFB}\u{4F55}\u{4E91}\u{5B58}\u{50A8}"
            alert.runModal()
            return
        }

        buildWindow()
    }

    private func buildWindow() {
        let colCount = remotes.count
        let rowCount = dirs.count
        let cellW: CGFloat = 100
        let labelW: CGFloat = 180
        let rowH: CGFloat = 26
        let padding: CGFloat = 20
        let topBarH: CGFloat = 80
        let bottomBarH: CGFloat = 52

        // Dynamic width: mode selector needs ~420, matrix needs labelW + cols*cellW
        let matrixW = labelW + CGFloat(colCount) * cellW
        let minModeW: CGFloat = 420
        let contentW = max(matrixW + padding * 2, minModeW + padding * 2)
        let matrixH = CGFloat(rowCount + 2) * rowH
        let maxMatrixH: CGFloat = 400
        let scrollH = min(matrixH, maxMatrixH)
        let contentH = topBarH + scrollH + bottomBarH + padding

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentW, height: max(contentH, 280)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "📊 同步规则配置"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false

        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        w.contentView = content
        let winW = content.bounds.width

        var y = content.bounds.height - padding

        // Mode selector row
        y -= 26
        let modeLabel = NSTextField(labelWithString: "模式:")
        modeLabel.frame = NSRect(x: padding, y: y, width: 40, height: 22)
        modeLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        content.addSubview(modeLabel)

        let modeW = min(winW - padding * 2 - 48, 380)
        modeControl = NSSegmentedControl(labels: ["🟢 自动（默认全部同步）", "🔒 手动（逐个指定）"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(modeChanged(_:)))
        modeControl.selectedSegment = rulesManager.rules.mode == "manual" ? 1 : 0
        modeControl.frame = NSRect(x: padding + 44, y: y - 1, width: modeW, height: 24)
        content.addSubview(modeControl)

        y -= 20
        let hintText = rulesManager.rules.mode == "manual"
            ? "手动模式: 新目录需手动勾选才会同步"
            : "自动模式: 新目录自动同步到所有云存储"
        let hint = NSTextField(labelWithString: hintText)
        hint.tag = 999
        hint.frame = NSRect(x: padding, y: y, width: winW - padding * 2, height: 16)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)

        // Scrollable matrix area
        y -= scrollH + 10
        let scrollW = winW - padding * 2
        let scrollView = NSScrollView(frame: NSRect(x: padding, y: y, width: scrollW, height: scrollH))
        scrollView.hasVerticalScroller = matrixH > maxMatrixH
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = matrixH > maxMatrixH ? .bezelBorder : .noBorder
        scrollView.drawsBackground = false

        let docW = max(scrollW, matrixW)
        let matrixView = NSView(frame: NSRect(x: 0, y: 0, width: docW, height: matrixH))
        var my = matrixH

        // Column headers
        my -= rowH
        for (j, remote) in remotes.enumerated() {
            let label = displayMap[remote.lowercased()] ?? remote
            let header = NSButton(title: label, target: self, action: #selector(toggleColumn(_:)))
            header.tag = j
            header.bezelStyle = .inline
            header.frame = NSRect(x: labelW + CGFloat(j) * cellW + 4, y: my, width: cellW - 8, height: rowH - 2)
            header.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            matrixView.addSubview(header)
        }

        // Separator line under headers
        let sepLine = NSBox(frame: NSRect(x: 0, y: my - 1, width: docW, height: 1))
        sepLine.boxType = .separator
        matrixView.addSubview(sepLine)

        // Matrix rows
        checkboxes = []
        for (i, dir) in dirs.enumerated() {
            my -= rowH

            // Alternate row background
            if i % 2 == 0 {
                let bg = NSView(frame: NSRect(x: 0, y: my, width: docW, height: rowH))
                bg.wantsLayer = true
                bg.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.04).cgColor
                matrixView.addSubview(bg)
            }

            let rowBtn = NSButton(title: "📁 \(dir)", target: self, action: #selector(toggleRow(_:)))
            rowBtn.tag = i
            rowBtn.bezelStyle = .inline
            rowBtn.alignment = .left
            rowBtn.frame = NSRect(x: 4, y: my, width: labelW - 12, height: rowH - 2)
            rowBtn.font = NSFont.systemFont(ofSize: 12)
            matrixView.addSubview(rowBtn)

            var row: [NSButton] = []
            for (j, _) in remotes.enumerated() {
                let cb = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                let cbX = labelW + CGFloat(j) * cellW + (cellW - 18) / 2
                cb.frame = NSRect(x: cbX, y: my + (rowH - 18) / 2, width: 18, height: 18)
                let isChecked = rulesManager.shouldSync(dir: dir, remote: remotes[j], allRemotes: remotes)
                cb.state = isChecked ? .on : .off
                matrixView.addSubview(cb)
                row.append(cb)
            }
            checkboxes.append(row)
        }

        // Separator before select-all
        my -= 1
        let sepLine2 = NSBox(frame: NSRect(x: labelW, y: my, width: docW - labelW, height: 1))
        sepLine2.boxType = .separator
        matrixView.addSubview(sepLine2)

        // Column "select all" buttons
        my -= rowH - 1
        for j in 0..<colCount {
            let btn = NSButton(title: "全选", target: self, action: #selector(selectAllColumn(_:)))
            btn.tag = j
            btn.bezelStyle = .inline
            btn.font = NSFont.systemFont(ofSize: 10)
            btn.frame = NSRect(x: labelW + CGFloat(j) * cellW + 14, y: my, width: cellW - 28, height: 20)
            matrixView.addSubview(btn)
        }

        scrollView.documentView = matrixView
        if let docView = scrollView.documentView {
            docView.scroll(NSPoint(x: 0, y: docView.bounds.height))
        }
        content.addSubview(scrollView)

        // Bottom buttons — right-aligned
        y = padding
        let syncBtn = NSButton(title: "保存并同步", target: self, action: #selector(saveAndSyncAction(_:)))
        syncBtn.bezelStyle = .rounded
        syncBtn.keyEquivalent = "\r"
        syncBtn.frame = NSRect(x: winW - padding - 120, y: y, width: 120, height: 30)
        content.addSubview(syncBtn)

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveAction(_:)))
        saveBtn.bezelStyle = .rounded
        saveBtn.frame = NSRect(x: winW - padding - 208, y: y, width: 80, height: 30)
        content.addSubview(saveBtn)

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancelAction(_:)))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: winW - padding - 296, y: y, width: 80, height: 30)
        content.addSubview(cancelBtn)

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let isManual = sender.selectedSegment == 1
        // Update hint
        if let content = window?.contentView {
            if let hint = content.viewWithTag(999) as? NSTextField {
                hint.stringValue = isManual
                    ? "\u{624B}\u{52A8}\u{6A21}\u{5F0F}: \u{65B0}\u{76EE}\u{5F55}\u{9700}\u{624B}\u{52A8}\u{52FE}\u{9009}\u{624D}\u{4F1A}\u{540C}\u{6B65}"
                    : "\u{81EA}\u{52A8}\u{6A21}\u{5F0F}: \u{65B0}\u{76EE}\u{5F55}\u{81EA}\u{52A8}\u{540C}\u{6B65}\u{5230}\u{6240}\u{6709}\u{4E91}\u{5B58}\u{50A8}"
            }
        }
    }

    @objc private func toggleColumn(_ sender: NSButton) {
        let col = sender.tag
        let allOn = checkboxes.allSatisfy { $0[col].state == .on }
        let newState: NSControl.StateValue = allOn ? .off : .on
        for row in checkboxes { row[col].state = newState }
    }

    @objc private func toggleRow(_ sender: NSButton) {
        let row = sender.tag
        let allOn = checkboxes[row].allSatisfy { $0.state == .on }
        let newState: NSControl.StateValue = allOn ? .off : .on
        for cb in checkboxes[row] { cb.state = newState }
    }

    @objc private func selectAllColumn(_ sender: NSButton) {
        let col = sender.tag
        let allOn = checkboxes.allSatisfy { $0[col].state == .on }
        let newState: NSControl.StateValue = allOn ? .off : .on
        for row in checkboxes { row[col].state = newState }
    }

    private func collectRules() {
        let isManual = modeControl.selectedSegment == 1
        rulesManager.rules.mode = isManual ? "manual" : "auto"
        var newRules: [String: [String]] = [:]

        for (i, dir) in dirs.enumerated() {
            var enabledRemotes: [String] = []
            for (j, remote) in remotes.enumerated() {
                if checkboxes[i][j].state == .on {
                    enabledRemotes.append(remote)
                }
            }

            if isManual {
                // Manual: store all mappings
                if !enabledRemotes.isEmpty {
                    newRules[dir] = enabledRemotes
                }
            } else {
                // Auto: only store exceptions (not all remotes)
                if Set(enabledRemotes) != Set(remotes) {
                    newRules[dir] = enabledRemotes
                }
            }
        }
        rulesManager.rules.rules = newRules
    }

    @objc private func cancelAction(_ sender: NSButton) {
        window?.close()
    }

    @objc private func saveAction(_ sender: NSButton) {
        collectRules()
        rulesManager.save()
        onSave?()
        window?.close()
    }

    @objc private func saveAndSyncAction(_ sender: NSButton) {
        collectRules()
        rulesManager.save()
        onSave?()
        window?.close()
        // Post notification to trigger sync
        NotificationCenter.default.post(name: NSNotification.Name("TriggerSync"), object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Config Model
class SyncConfig: ObservableObject {
    @Published var syncInterval: Int = 1800
    @Published var conflictResolve: String = "newer"
    @Published var conflictSilent: Bool = true
    @Published var maxDeletePct: Int = 50
    @Published var socks5Proxy: String = ""
    @Published var logRetainDays: Int = 7
    @Published var remotesList: String = ""     // 云存储列表，空格分隔，如 "onedrive: gdrive:"
    @Published var localPath: String = ""

    /// Primary remote name (first in list, for display)
    var remoteName: String {
        let first = remotesList.components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "") }
            .first { !$0.isEmpty }
        return first ?? "cloud"
    }

    private let configPath: String

    /// Public accessor for the config file path
    var configFilePath: String { configPath }

    /// Display name for the remote (e.g. "OneDrive", "Google Drive")
    var remoteDisplayName: String {
        let name = remoteName.replacingOccurrences(of: ":", with: "")
        let map: [String: String] = [
            "onedrive": "OneDrive", "gdrive": "Google Drive", "drive": "Google Drive",
            "dropbox": "Dropbox", "s3": "S3", "webdav": "WebDAV", "sftp": "SFTP"
        ]
        return map[name.lowercased()] ?? name
    }

    /// All active remotes parsed from REMOTES config
    var activeRemotes: [String] {
        let explicit = remotesList.components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "") }
            .filter { !$0.isEmpty }
        if !explicit.isEmpty { return explicit }
        // Fallback: list all rclone remotes
        let allRemotes = listRemotes()
        return allRemotes.isEmpty ? ["cloud"] : allRemotes
    }

    /// Display name for the status bar
    var statusDisplayName: String {
        let remotes = activeRemotes
        if remotes.count == 1 {
            return remoteDisplayName
        }
        return "\(remotes.count) 个云存储"
    }

    init() {
        // Resolve config path: look next to the running binary first, then fallback
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            Bundle.main.bundlePath.components(separatedBy: "/").dropLast(3).joined(separator: "/") + "/config.env",
            "\(home)/OneDrive/Tools/rclone-sync-mac/config.env"
        ]
        configPath = candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "\(home)/OneDrive/Tools/rclone-sync-mac/config.env"
        load()
    }

    func load() {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var value = parts.dropFirst().joined(separator: "=")
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "$HOME", with: FileManager.default.homeDirectoryForCurrentUser.path)
            // Remove inline comments
            if let commentIndex = value.range(of: " #") {
                value = String(value[..<commentIndex.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
            switch key {
            case "SYNC_INTERVAL": syncInterval = Int(value) ?? 1800
            case "CONFLICT_RESOLVE": conflictResolve = value
            case "CONFLICT_SILENT": conflictSilent = (value == "true")
            case "MAX_DELETE_PCT": maxDeletePct = Int(value) ?? 50
            case "SOCKS5_PROXY": socks5Proxy = value
            case "LOG_RETAIN_DAYS": logRetainDays = Int(value) ?? 7
            case "REMOTE":
                // Backward compat: old single REMOTE, only use if REMOTES not set
                if remotesList.isEmpty {
                    remotesList = value
                }
            case "REMOTES": remotesList = value
            case "LOCAL_PATH": localPath = value
            default: break
            }
        }
    }

    func save() {
        let home = "$HOME"
        let savePath = localPath.isEmpty ? "\(home)/CloudSync" : localPath
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: home)
        let remotesLine = remotesList.isEmpty ? "" : remotesList
        let content = """
        # ==============================================================================
        # Cloud Sync - 配置文件
        # 支持所有 rclone 兼容的云存储服务
        # ==============================================================================

        # ---- 基础路径 ----
        LOCAL_PATH="\(savePath)"
        REMOTES="\(remotesLine)"                  # 云存储列表（空格分隔），示例: "onedrive: gdrive: dropbox:"

        # ---- 同步设置 ----
        SYNC_INTERVAL=\(syncInterval)
        CONFLICT_RESOLVE="\(conflictResolve)"
        CONFLICT_SILENT=\(conflictSilent)
        MAX_DELETE_PCT=\(maxDeletePct)

        # ---- 网络 ----
        SOCKS5_PROXY="\(socks5Proxy)"

        # ---- 日志 ----
        LOG_RETAIN_DAYS=\(logRetainDays)

        # ---- 数据目录（一般无需修改） ----
        DATA_DIR="$HOME/.local/share/rclone-sync-mac"
        """
        let lines = content.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .init(charactersIn: " "))
        }
        try? lines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// List all configured rclone remotes
    func listRemotes() -> [String] {
        let task = Process()
        let pipe = Pipe()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; rclone listremotes 2>/dev/null"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(":") ? String($0.dropLast()) : $0 }
    }

    /// Switch to a single remote
    func switchRemote(to name: String) {
        remotesList = "\(name):"
        save()
    }

    /// Toggle a remote on/off
    func toggleRemote(_ name: String) {
        var currentActive = activeRemotes

        if currentActive.contains(name) {
            // Turning off
            currentActive.removeAll { $0 == name }
            if currentActive.isEmpty {
                return  // Can't remove the last one
            }
        } else {
            // Turning on
            currentActive.append(name)
        }

        remotesList = currentActive.map { "\($0):" }.joined(separator: " ")
        save()
    }

    /// Update the launchd plist interval and reload
    func updateLaunchdInterval() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plistSrc = "\(home)/OneDrive/Tools/rclone-sync-mac/com.rclone.sync-mac.plist"
        let plistDst = "\(home)/Library/LaunchAgents/com.rclone.sync-mac.plist"

        guard let data = try? String(contentsOfFile: plistSrc, encoding: .utf8) else { return }

        // Replace StartInterval value
        let pattern = "(<key>StartInterval</key>\\s*<integer>)\\d+(</integer>)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(data.startIndex..., in: data)
        let updated = regex.stringByReplacingMatches(in: data, range: range,
                                                      withTemplate: "$1\(syncInterval)$2")

        try? updated.write(toFile: plistSrc, atomically: true, encoding: .utf8)
        try? updated.write(toFile: plistDst, atomically: true, encoding: .utf8)

        // Reload launchd
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", """
            launchctl bootout gui/\(getuid()) \(plistDst) 2>/dev/null; \
            launchctl bootstrap gui/\(getuid()) \(plistDst) 2>/dev/null
        """]
        try? task.run()
    }
}

// MARK: - Status Bar Controller
class StatusBarController: ObservableObject {
    private var statusItem: NSStatusItem
    private var syncTimers: [String: Timer] = [:]  // Per-remote scheduled timers
    private var trackedPIDs: Set<pid_t> = []         // PIDs launched by this app
    private var statusMonitorTimer: Timer?  // Status polling timer
    private var fileMonitor: DispatchSourceFileSystemObject?
    @Published var remoteStatuses: [String: RemoteStatus] = [:]  // Per-remote status
    @Published var nextSyncTimes: [String: Date] = [:]  // Per-remote next scheduled sync
    @Published var isPaused: Bool = false
    private let config = SyncConfig()

    private let dataDirPath: String
    private let syncScriptPath: String
    private let logDirPath: String

    /// Computed aggregate status
    var isSyncing: Bool {
        remoteStatuses.values.contains { $0.status == "syncing" }
    }
    var hasErrors: Bool {
        remoteStatuses.values.contains { $0.status == "error" }
    }
    var aggregateStatus: String {
        if isSyncing { return "syncing" }
        if hasErrors { return "error" }
        if remoteStatuses.values.allSatisfy({ $0.status == "success" }) && !remoteStatuses.isEmpty { return "success" }
        return "idle"
    }
    var failedRemotes: [RemoteStatus] {
        remoteStatuses.values.filter { $0.status == "error" }
    }

    /// Earliest next sync time across all remotes
    var earliestNextSync: Date? {
        nextSyncTimes.values.min()
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        dataDirPath = "\(home)/.local/share/rclone-sync-mac"
        syncScriptPath = "\(home)/OneDrive/Tools/rclone-sync-mac/sync.sh"
        logDirPath = "\(dataDirPath)/logs"

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        setupStatusItem()
        loadStatus()
        startFileMonitor()

        // Poll status every 10s as fallback (also refreshes next-sync countdown)
        statusMonitorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.loadStatus()
        }

        // Listen for sync trigger from rules window
        NotificationCenter.default.addObserver(forName: NSNotification.Name("TriggerSync"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.syncAllRemotes()
        }

        // Start scheduled sync timers
        setupScheduledTimers()
    }

    deinit {
        syncTimers.values.forEach { $0.invalidate() }
        statusMonitorTimer?.invalidate()
        fileMonitor?.cancel()
    }

    // MARK: - Scheduled Sync Timers

    /// Setup staggered per-remote timers. First remote syncs immediately, others staggered.
    func setupScheduledTimers() {
        // Invalidate existing timers
        syncTimers.values.forEach { $0.invalidate() }
        syncTimers.removeAll()
        nextSyncTimes.removeAll()

        guard !isPaused else { return }

        let remotes = config.activeRemotes
        guard !remotes.isEmpty else { return }

        // Ensure we know current state before scheduling
        loadStatus()

        let interval = Double(config.syncInterval)
        // Evenly distribute syncs across the interval
        let stagger = remotes.count > 1 ? interval / Double(remotes.count) : interval

        for (i, remote) in remotes.enumerated() {
            let remoteName = remote.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let initialDelay = max(5, stagger * Double(i))  // min 5s to avoid immediate fire
            let fireDate = Date().addingTimeInterval(initialDelay)

            nextSyncTimes[remoteName] = fireDate

            // Create a repeating timer with staggered start
            let timer = Timer(fire: fireDate, interval: interval, repeats: true) { [weak self] _ in
                self?.scheduledSync(for: remoteName)
            }
            RunLoop.main.add(timer, forMode: .common)
            syncTimers[remoteName] = timer
        }
        buildMenu()
    }

    /// Called by scheduled timer — skips if already syncing
    private func scheduledSync(for remote: String) {
        guard !isPaused else { return }

        // Update next sync time
        let interval = Double(config.syncInterval)
        nextSyncTimes[remote] = Date().addingTimeInterval(interval)

        // Skip if this remote is already syncing or in error state
        if let rs = remoteStatuses[remote] {
            if rs.status == "syncing" { return }
            if rs.status == "error" { return }
        }

        // Double-check: skip if lock file exists with a running process
        let lockFile = dataDirPath + "/sync-\(remote).lock"
        if let pidStr = try? String(contentsOfFile: lockFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr), pid > 0, kill(pid, 0) == 0 {
            return  // Another process is running
        }

        // Launch sync (don't kill existing — this is a scheduled sync, not manual override)
        launchSync(for: remote, extraArgs: [])
    }

    /// Add a timer for a newly added remote (called when remotes change)
    func scheduleTimerForNewRemote(_ remoteName: String) {
        guard !isPaused else { return }

        let interval = Double(config.syncInterval)
        // Find the best stagger offset: halfway between existing timers
        let existingFireTimes = syncTimers.values.compactMap { $0.fireDate }
        let now = Date()
        var bestDelay: TimeInterval = 0
        if !existingFireTimes.isEmpty {
            // Stagger evenly among all remotes including new one
            let totalRemotes = syncTimers.count + 1
            let stagger = interval / Double(totalRemotes)
            bestDelay = stagger * Double(syncTimers.count)
        }

        let fireDate = now.addingTimeInterval(bestDelay)
        nextSyncTimes[remoteName] = fireDate

        let timer = Timer(fire: fireDate, interval: interval, repeats: true) { [weak self] _ in
            self?.scheduledSync(for: remoteName)
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimers[remoteName] = timer
        buildMenu()
    }

    /// Format remaining time for display
    private func formatTimeRemaining(_ date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "即将同步" }
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        if mins > 0 {
            return "\(mins)分\(secs)秒后"
        }
        return "\(secs)秒后"
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        updateIcon(for: "idle")
        if let button = statusItem.button {
            button.toolTip = "Cloud Sync (\(config.statusDisplayName))"
        }
        buildMenu()
    }

    private func updateIcon(for status: String) {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch status {
        case "syncing":  symbol = "arrow.triangle.2.circlepath"
        case "success":  symbol = "checkmark.icloud"
        case "error":    symbol = "exclamationmark.icloud"
        case "skipped":  symbol = "pause.circle"
        case "paused":   symbol = "pause.circle.fill"
        default:         symbol = "icloud"
        }

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: status) {
            image.isTemplate = true
            button.image = image
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        // Status header
        let statusItem = NSMenuItem(title: statusTitle(), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.attributedTitle = NSAttributedString(
            string: statusTitle(),
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        )
        menu.addItem(statusItem)

        // Last sync time — show most recent across all remotes
        let latestTime = remoteStatuses.values
            .compactMap { $0.timestampLocal.isEmpty ? nil : $0.timestampLocal }
            .sorted().last
        if let ts = latestTime {
            let timeItem = NSMenuItem(title: "  上次同步: \(ts)", action: nil, keyEquivalent: "")
            timeItem.isEnabled = false
            timeItem.attributedTitle = NSAttributedString(
                string: "  上次: \(ts)",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            )
            menu.addItem(timeItem)
        }

        // Per-remote status (show ALL active remotes, not just those with status files)
        let allActiveRemotes = config.activeRemotes.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ":")) }
        for name in allActiveRemotes.sorted() {
            let icon: String
            let color: NSColor
            var detail: String

            if let rs = remoteStatuses[name] {
                detail = rs.message
                switch rs.status {
                case "syncing": icon = "🔄"; color = .systemBlue
                case "success":
                    icon = "✅"; color = .systemGreen
                    if let nextTime = nextSyncTimes[name] {
                        detail = "同步完成 · \(formatTimeRemaining(nextTime))"
                    }
                case "error":
                    icon = "❌"; color = .systemRed
                    detail = "\(rs.message) · 已暂停自动同步"
                default:        icon = "☁️"; color = .secondaryLabelColor
                }
            } else {
                // No status file yet — show next sync countdown
                icon = "⏳"; color = .secondaryLabelColor
                if let nextTime = nextSyncTimes[name] {
                    detail = "等待首次同步 · \(formatTimeRemaining(nextTime))"
                } else {
                    detail = "等待同步"
                }
            }
            let item = NSMenuItem(title: "  \(icon) \(name): \(detail)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(
                string: "  \(icon) \(name): \(detail)",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color]
            )
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())

        // Sync Now — submenu with all + individual remotes
        let syncMenuItem = NSMenuItem(title: "📡 立即同步", action: nil, keyEquivalent: "")
        let syncSubmenu = NSMenu()

        let syncAll = NSMenuItem(title: "📡 同步全部云存储", action: #selector(syncNow(_:)), keyEquivalent: "s")
        syncAll.target = self
        syncAll.isEnabled = !isSyncing
        syncAll.toolTip = "立即触发所有云存储的双向同步"
        syncSubmenu.addItem(syncAll)
        syncSubmenu.addItem(NSMenuItem.separator())

        // Individual remote sync options
        let allRemotes = config.activeRemotes
        let displayMap: [String: String] = [
            "onedrive": "☁️ OneDrive", "gdrive": "📁 Google Drive", "drive": "📁 Google Drive",
            "dropbox": "📦 Dropbox", "s3": "🪣 S3", "webdav": "🌐 WebDAV", "sftp": "🖥️ SFTP"
        ]
        for remote in allRemotes {
            let remoteName = remote.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let remoteSyncing = remoteStatuses[remoteName]?.status == "syncing"
            let label = displayMap[remoteName.lowercased()] ?? "💾 \(remoteName)"
            let item = NSMenuItem(title: "同步 \(label)", action: #selector(syncSingleRemote(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = remoteName
            item.isEnabled = !remoteSyncing
            if remoteSyncing {
                item.attributedTitle = NSAttributedString(
                    string: "🔄 \(label) 同步中...",
                    attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]
                )
            }
            syncSubmenu.addItem(item)
        }

        syncMenuItem.submenu = syncSubmenu
        menu.addItem(syncMenuItem)

        // Dry Run — submenu with all + individual remotes
        let dryRunMenuItem = NSMenuItem(title: "👀 预览同步", action: nil, keyEquivalent: "")
        let dryRunSubmenu = NSMenu()

        let dryRunAll = NSMenuItem(title: "👀 预览全部云存储", action: #selector(dryRun(_:)), keyEquivalent: "d")
        dryRunAll.target = self
        dryRunAll.isEnabled = !isSyncing
        dryRunAll.toolTip = "模拟同步所有云存储，不实际传输文件"
        dryRunSubmenu.addItem(dryRunAll)
        dryRunSubmenu.addItem(NSMenuItem.separator())

        for remote in allRemotes {
            let remoteName = remote.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let label = displayMap[remoteName.lowercased()] ?? "💾 \(remoteName)"
            let item = NSMenuItem(title: "预览 \(label)", action: #selector(dryRunSingleRemote(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = remoteName
            dryRunSubmenu.addItem(item)
        }

        dryRunMenuItem.submenu = dryRunSubmenu
        menu.addItem(dryRunMenuItem)

        // Single-remote sync (show failed remotes for retry)
        let failed = failedRemotes
        if !failed.isEmpty && !isSyncing {
            let retryItem = NSMenuItem(title: "🔁 重试失败的云存储", action: nil, keyEquivalent: "")
            retryItem.toolTip = "重新启动同步失败的云存储"
            let retryMenu = NSMenu()
            for rs in failed {
                let remoteName = rs.remote ?? "unknown"
                let item = NSMenuItem(title: "📡 重试同步 \(remoteName)", action: #selector(syncSingleRemote(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = remoteName
                retryMenu.addItem(item)
            }
            retryItem.submenu = retryMenu
            menu.addItem(retryItem)
        }

        // 清除缓存 — per-remote submenu
        let clearCacheMenuItem = NSMenuItem(title: "🧹 清除缓存", action: nil, keyEquivalent: "")
        let clearCacheSubmenu = NSMenu()
        for remote in allRemotes {
            let remoteName = remote.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let label = displayMap[remoteName.lowercased()] ?? "💾 \(remoteName)"
            let item = NSMenuItem(title: "🧹 \(label)", action: #selector(clearCacheForRemote(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = remoteName
            item.toolTip = "清除该云存储的 bisync 缓存，下次同步时会自动 resync"
            clearCacheSubmenu.addItem(item)
        }
        clearCacheMenuItem.submenu = clearCacheSubmenu
        menu.addItem(clearCacheMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Pause/Resume
        let pauseTitle = isPaused ? "▶️ 恢复同步" : "⏸️ 暂停同步"
        let pause = NSMenuItem(title: pauseTitle, action: #selector(togglePause(_:)), keyEquivalent: "p")
        pause.target = self
        pause.toolTip = isPaused ? "恢复定时自动同步" : "暂停定时自动同步，不影响手动同步"
        menu.addItem(pause)

        menu.addItem(NSMenuItem.separator())

        // Cloud Remote submenu (multi-select with checkmarks)
        let activeCount = config.activeRemotes.count
        let remoteLabel = activeCount > 1 ? "☁️ 云存储: \(activeCount) 个已启用" : "☁️ 云存储: \(config.remoteDisplayName)"
        let remoteMenuItem = NSMenuItem(title: remoteLabel, action: nil, keyEquivalent: "")
        let remoteSubmenu = NSMenu()

        // Hint
        let hintItem = NSMenuItem(title: "✅ = 已启用，点击切换", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        hintItem.attributedTitle = NSAttributedString(
            string: "可同时启用多个云存储（串行同步）",
            attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor]
        )
        remoteSubmenu.addItem(hintItem)
        remoteSubmenu.addItem(NSMenuItem.separator())

        let remotes = config.listRemotes()
        if remotes.isEmpty {
            let noRemote = NSMenuItem(title: "(未配置任何 remote)", action: nil, keyEquivalent: "")
            noRemote.isEnabled = false
            remoteSubmenu.addItem(noRemote)
        } else {
            let actives = config.activeRemotes.map { $0.lowercased() }
            for remote in remotes {
                let displayMap: [String: String] = [
                    "onedrive": "☁️ OneDrive", "gdrive": "📁 Google Drive", "drive": "📁 Google Drive",
                    "dropbox": "📦 Dropbox", "s3": "🪣 S3", "webdav": "🌐 WebDAV", "sftp": "🖥️ SFTP"
                ]
                let label = displayMap[remote.lowercased()] ?? "💾 \(remote)"
                let item = NSMenuItem(title: label, action: #selector(toggleRemoteAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = remote
                item.state = actives.contains(remote.lowercased()) ? .on : .off
                remoteSubmenu.addItem(item)
            }
        }
        remoteSubmenu.addItem(NSMenuItem.separator())
        let addRemote = NSMenuItem(title: "➕ 添加新云存储...", action: #selector(runSetup(_:)), keyEquivalent: "")
        addRemote.target = self
        remoteSubmenu.addItem(addRemote)
        remoteMenuItem.submenu = remoteSubmenu
        menu.addItem(remoteMenuItem)

        // Settings submenu
        let settingsMenu = NSMenu()

        // Interval
        let intervalItem = NSMenuItem(title: "同步间隔", action: nil, keyEquivalent: "")
        let intervalSubmenu = NSMenu()
        for (label, secs) in [("5 分钟", 300), ("10 分钟", 600), ("15 分钟", 900),
                               ("30 分钟", 1800), ("1 小时", 3600), ("2 小时", 7200)] {
            let item = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = secs
            item.state = config.syncInterval == secs ? .on : .off
            intervalSubmenu.addItem(item)
        }
        intervalItem.submenu = intervalSubmenu
        settingsMenu.addItem(intervalItem)

        // Conflict strategy
        let conflictItem = NSMenuItem(title: "冲突策略", action: nil, keyEquivalent: "")
        let conflictSubmenu = NSMenu()
        for (label, value) in [("以较新文件为准", "newer"), ("以较旧文件为准", "older"),
                                ("以较大文件为准", "larger"), ("以本地文件为准", "path1"),
                                ("以远程文件为准", "path2")] {
            let item = NSMenuItem(title: label, action: #selector(setConflict(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = config.conflictResolve == value ? .on : .off
            conflictSubmenu.addItem(item)
        }
        conflictItem.submenu = conflictSubmenu
        settingsMenu.addItem(conflictItem)

        // Silent conflict
        let silentItem = NSMenuItem(
            title: config.conflictSilent ? "冲突通知: 静默" : "冲突通知: 提醒",
            action: #selector(toggleSilent(_:)), keyEquivalent: ""
        )
        silentItem.target = self
        settingsMenu.addItem(silentItem)

        // Proxy
        let proxyItem = NSMenuItem(
            title: config.socks5Proxy.isEmpty ? "代理: 未设置" : "代理: \(config.socks5Proxy)",
            action: #selector(setProxy(_:)), keyEquivalent: ""
        )
        proxyItem.target = self
        settingsMenu.addItem(proxyItem)

        let settingsMenuItem = NSMenuItem(title: "⚙️ 设置", action: nil, keyEquivalent: "")
        settingsMenuItem.submenu = settingsMenu
        menu.addItem(settingsMenuItem)

        // Sync Rules (show when 2+ rclone remotes available)
        if config.listRemotes().count > 1 {
            let rulesItem = NSMenuItem(title: "📊 同步规则", action: #selector(openSyncRules(_:)), keyEquivalent: "r")
            rulesItem.target = self
            rulesItem.toolTip = "配置每个子目录同步到哪些云存储"
            menu.addItem(rulesItem)
        }

        menu.addItem(NSMenuItem.separator())

        // View Log — per-remote submenu
        let logMenuItem = NSMenuItem(title: "📋 查看日志", action: nil, keyEquivalent: "")
        let logSubmenu = NSMenu()

        for remote in config.activeRemotes {
            let remoteName = remote.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let item = NSMenuItem(title: "📋 \(remoteName) 日志", action: #selector(openLogForRemote(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = remoteName
            logSubmenu.addItem(item)
        }
        logSubmenu.addItem(NSMenuItem.separator())
        let openDirItem = NSMenuItem(title: "📂 打开日志目录", action: #selector(openLogDir(_:)), keyEquivalent: "l")
        openDirItem.target = self
        logSubmenu.addItem(openDirItem)

        logMenuItem.submenu = logSubmenu
        menu.addItem(logMenuItem)

        // Open config
        let configItem = NSMenuItem(title: "📝 编辑配置", action: #selector(openConfig(_:)), keyEquivalent: ",")
        configItem.target = self
        configItem.toolTip = "打开 config.env 配置文件编辑器"
        menu.addItem(configItem)

        // Open sync folder (show current path)
        let localPath = config.localPath
        let folderItem = NSMenuItem(title: "📂 同步目录: \(localPath)", action: #selector(openFolder(_:)), keyEquivalent: "o")
        folderItem.target = self
        folderItem.toolTip = "在 Finder 中打开本地同步目录"
        menu.addItem(folderItem)

        // Change sync folder
        let changeFolderItem = NSMenuItem(title: "📁 更改同步目录...", action: #selector(changeSyncFolder(_:)), keyEquivalent: "")
        changeFolderItem.target = self
        changeFolderItem.toolTip = "选择新的本地文件夹作为同步根目录"
        menu.addItem(changeFolderItem)

        menu.addItem(NSMenuItem.separator())

        // Resync
        let resyncItem = NSMenuItem(title: "🔄 重新初始化同步", action: #selector(resync(_:)), keyEquivalent: "")
        resyncItem.target = self
        resyncItem.toolTip = "重新建立本地和远程的同步基准线，用于首次使用或修复同步异常"
        menu.addItem(resyncItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quit = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        self.statusItem.menu = menu
    }

    private func statusTitle() -> String {
        if isPaused { return "⏸️ 同步已暂停" }
        if remoteStatuses.isEmpty { return "☁️ \(config.statusDisplayName) 同步" }

        let syncingRemotes = remoteStatuses.filter { $0.value.status == "syncing" }
        let errorRemotes = remoteStatuses.filter { $0.value.status == "error" }

        if !syncingRemotes.isEmpty {
            let names = syncingRemotes.keys.sorted().joined(separator: ", ")
            if remoteStatuses.count > 1 {
                return "🔄 \(names) 同步中... (\(syncingRemotes.count)/\(remoteStatuses.count))"
            }
            return "🔄 \(names) 同步中..."
        }
        if !errorRemotes.isEmpty {
            let names = errorRemotes.keys.sorted().joined(separator: ", ")
            return "❌ \(names) 同步失败"
        }
        if remoteStatuses.values.allSatisfy({ $0.status == "success" }) {
            return "✅ 同步正常"
        }
        return "☁️ \(config.statusDisplayName) 同步"
    }

    // MARK: - File Monitor

    private func startFileMonitor() {
        // Watch the data directory for any status file changes
        try? FileManager.default.createDirectory(atPath: dataDirPath, withIntermediateDirectories: true)

        let fd = open(dataDirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .main
        )
        fileMonitor?.setEventHandler { [weak self] in
            self?.loadStatus()
        }
        fileMonitor?.setCancelHandler {
            close(fd)
        }
        fileMonitor?.resume()
    }

    // MARK: - Status Loading

    private func loadStatus() {
        // Scan for all status-{remote}.json files
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dataDirPath) else { return }

        var newStatuses: [String: RemoteStatus] = [:]

        for file in files {
            guard file.hasPrefix("status-") && file.hasSuffix(".json") else { continue }
            let remoteName = String(file.dropFirst(7).dropLast(5))  // "status-xxx.json" -> "xxx"
            guard !remoteName.isEmpty else { continue }

            let filePath = dataDirPath + "/" + file
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                  var rs = try? JSONDecoder().decode(RemoteStatus.self, from: data) else { continue }

            // Check for stale syncing status
            if rs.status == "syncing" {
                let lockFile = dataDirPath + "/sync-\(remoteName).lock"
                var processRunning = false

                if let pidStr = try? String(contentsOfFile: lockFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                   let pid = Int32(pidStr), pid > 0 {
                    processRunning = (kill(pid, 0) == 0)
                }

                if !processRunning {
                    // Stale syncing status — correct it
                    rs.status = "error"
                    rs.message = "同步中断"
                    if let encoded = try? JSONEncoder().encode(rs) {
                        try? encoded.write(to: URL(fileURLWithPath: filePath))
                    }
                }
            }

            newStatuses[remoteName] = rs
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.remoteStatuses = newStatuses
            let displayStatus = self.isPaused ? "paused" : self.aggregateStatus
            self.updateIcon(for: displayStatus)
            self.buildMenu()
        }
    }

    // MARK: - Actions

    @objc private func syncNow(_ sender: NSMenuItem) {
        syncAllRemotes()
    }

    @objc private func dryRun(_ sender: NSMenuItem) {
        syncAllRemotes(extraArgs: ["--dry-run"])
    }

    @objc private func dryRunSingleRemote(_ sender: NSMenuItem) {
        guard let remote = sender.representedObject as? String else { return }
        runSyncForRemote(remote, extraArgs: ["--dry-run"])
    }

    @objc private func syncSingleRemote(_ sender: NSMenuItem) {
        guard let remote = sender.representedObject as? String else { return }
        runSyncForRemote(remote, extraArgs: [])
    }

    @objc private func resyncSingleRemote(_ sender: NSMenuItem) {
        guard let remote = sender.representedObject as? String else { return }
        runSyncForRemote(remote, extraArgs: ["--resync"])
    }

    @objc private func clearCacheForRemote(_ sender: NSMenuItem) {
        guard let remote = sender.representedObject as? String else { return }

        // If healthy, warn user
        if let rs = remoteStatuses[remote], rs.status == "success" {
            let alert = NSAlert()
            alert.messageText = "\u{26A0}\u{FE0F} \(remote) \u{72B6}\u{6001}\u{6B63}\u{5E38}"
            alert.informativeText = "\u{8BE5}\u{4E91}\u{5B58}\u{50A8}\u{5F53}\u{524D}\u{540C}\u{6B65}\u{6B63}\u{5E38}\u{FF0C}\u{6E05}\u{9664}\u{7F13}\u{5B58}\u{540E}\u{4E0B}\u{6B21}\u{540C}\u{6B65}\u{5C06}\u{6267}\u{884C}\u{5B8C}\u{6574}\u{7684} resync\u{FF0C}\u{53EF}\u{80FD}\u{9700}\u{8981}\u{8F83}\u{957F}\u{65F6}\u{95F4}\u{3002}\n\n\u{786E}\u{5B9A}\u{8981}\u{6E05}\u{9664}\u{5417}\u{FF1F}"
            alert.addButton(withTitle: "\u{6E05}\u{9664}\u{7F13}\u{5B58}")
            alert.addButton(withTitle: "\u{53D6}\u{6D88}")
            alert.alertStyle = .warning
            if alert.runModal() != .alertFirstButtonReturn { return }
        }

        // Clear bisync cache for this remote
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cachedir = "\(home)/Library/Caches/rclone/bisync"
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: cachedir) {
            var cleaned = 0
            for f in files where f.contains(remote) {
                try? fm.removeItem(atPath: "\(cachedir)/\(f)")
                cleaned += 1
            }
            notify("Cloud Sync", "\u{5DF2}\u{6E05}\u{9664} \(remote) \u{7684} \(cleaned) \u{4E2A}\u{7F13}\u{5B58}\u{6587}\u{4EF6}")
        }
        buildMenu()
    }

    @objc private func resync(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "重新初始化同步"

        if isSyncing {
            alert.informativeText = "当前有同步正在运行，重新初始化会先终止当前同步。\n\n确定要继续吗？"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "先预览")
            alert.addButton(withTitle: "直接执行")
            alert.addButton(withTitle: "取消")
        } else {
            alert.informativeText = "这将重新建立本地和远程的同步基准线。通常在首次使用或同步异常时使用。\n\n是否先预览（dry-run）？"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "先预览")
            alert.addButton(withTitle: "直接执行")
            alert.addButton(withTitle: "取消")
        }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            killAllSyncs()
            syncAllRemotes(extraArgs: ["--resync", "--dry-run"])
        case .alertSecondButtonReturn:
            killAllSyncs()
            syncAllRemotes(extraArgs: ["--resync"])
        default:
            break
        }
    }

    // MARK: - Kill Sync

    /// Kill sync process for a specific remote (and its child processes)
    private func killSyncFor(remote: String) {
        let lockFile = dataDirPath + "/sync-\(remote).lock"
        guard let pidStr = try? String(contentsOfFile: lockFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr), pid > 0,
              kill(pid, 0) == 0 else { return }

        // First kill child processes (rclone, tee, etc.)
        let pkillTask = Process()
        pkillTask.launchPath = "/bin/bash"
        pkillTask.arguments = ["-c", "pkill -P \(pid) 2>/dev/null"]
        try? pkillTask.run()
        pkillTask.waitUntilExit()

        // Then kill the sync.sh itself
        kill(pid, SIGTERM)
        // Wait up to 2s for graceful exit
        for _ in 0..<20 {
            usleep(100_000)
            if kill(pid, 0) != 0 { break }
        }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            usleep(200_000)
        }
        // Clean up
        if kill(pid, 0) != 0 {
            trackedPIDs.remove(pid)
        }
        try? FileManager.default.removeItem(atPath: lockFile)
    }

    /// Kill all running sync processes (only tracked PIDs)
    private func killAllSyncs() {
        let fm = FileManager.default
        // Kill via lock files (tracked processes)
        if let files = try? fm.contentsOfDirectory(atPath: dataDirPath) {
            for file in files {
                guard file.hasPrefix("sync-") && file.hasSuffix(".lock") else { continue }
                let remoteName = String(file.dropFirst(5).dropLast(5))
                killSyncFor(remote: remoteName)
            }
        }
        // Kill any remaining tracked PIDs not covered by lock files
        for pid in trackedPIDs {
            guard kill(pid, 0) == 0 else { continue }  // Already dead
            kill(pid, SIGTERM)
            usleep(500_000)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL); usleep(200_000) }
        }
        // Only remove PIDs confirmed dead
        trackedPIDs = trackedPIDs.filter { kill($0, 0) == 0 }
        // Clean up any remaining lock files
        if let files = try? fm.contentsOfDirectory(atPath: dataDirPath) {
            for file in files where file.hasPrefix("sync-") && file.hasSuffix(".lock") {
                try? fm.removeItem(atPath: dataDirPath + "/" + file)
            }
        }
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        isPaused.toggle()
        if isPaused {
            killAllSyncs()
            // Stop all scheduled timers
            syncTimers.values.forEach { $0.invalidate() }
            syncTimers.removeAll()
            nextSyncTimes.removeAll()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let plist = "\(home)/Library/LaunchAgents/com.rclone.sync-mac.plist"
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "launchctl bootout gui/\(getuid()) \(plist) 2>/dev/null"]
            try? task.run()
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let plist = "\(home)/Library/LaunchAgents/com.rclone.sync-mac.plist"
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "launchctl bootstrap gui/\(getuid()) \(plist) 2>/dev/null"]
            try? task.run()
            // Restart scheduled timers
            setupScheduledTimers()
        }
        loadStatus()
    }

    // MARK: - Status Display Updater

    private func statusDisplayUpdater() {
        let displayStatus = isPaused ? "paused" : aggregateStatus
        updateIcon(for: displayStatus)
        buildMenu()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        config.syncInterval = sender.tag
        config.save()
        config.updateLaunchdInterval()
        setupScheduledTimers()  // Reschedule with new interval
    }

    @objc private func setConflict(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        config.conflictResolve = value
        config.save()
        buildMenu()
    }

    @objc private func toggleSilent(_ sender: NSMenuItem) {
        config.conflictSilent.toggle()
        config.save()
        buildMenu()
    }

    @objc private func setProxy(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "设置 SOCKS5 代理"
        alert.informativeText = "留空表示不使用代理\n格式: socks5://host:port"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = config.socks5Proxy
        input.placeholderString = "socks5://127.0.0.1:7890"
        alert.accessoryView = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            config.socks5Proxy = input.stringValue.trimmingCharacters(in: .whitespaces)
            config.save()
            buildMenu()
        }
    }

    @objc private func openLogForRemote(_ sender: NSMenuItem) {
        guard let remoteName = sender.representedObject as? String else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logDirPath) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: logDirPath))
            return
        }
        // Find the most recent log for this remote
        let logFiles = files.filter { $0.contains("_\(remoteName).log") }.sorted().reversed()
        if let latest = logFiles.first {
            NSWorkspace.shared.open(URL(fileURLWithPath: "\(logDirPath)/\(latest)"))
        } else {
            // Fallback: open any recent log
            let anyLogs = files.filter { $0.hasPrefix("sync_") && $0.hasSuffix(".log") }.sorted().reversed()
            if let latest = anyLogs.first {
                NSWorkspace.shared.open(URL(fileURLWithPath: "\(logDirPath)/\(latest)"))
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: logDirPath))
            }
        }
    }

    @objc private func openLogDir(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: logDirPath))
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        // Legacy: open most recent log
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logDirPath) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: logDirPath))
            return
        }
        let logFiles = files.filter { $0.hasPrefix("sync_") && $0.hasSuffix(".log") }.sorted().reversed()
        if let latest = logFiles.first {
            NSWorkspace.shared.open(URL(fileURLWithPath: "\(logDirPath)/\(latest)"))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: logDirPath))
        }
    }

    @objc private func openConfig(_ sender: NSMenuItem) {
        let configPath = config.configFilePath
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            let alert = NSAlert()
            alert.messageText = "无法读取配置文件"
            alert.informativeText = configPath
            alert.runModal()
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "📝 编辑配置 - config.env"
        w.center()
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 400, height: 300)

        let container = NSView(frame: w.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        w.contentView = container

        // Scroll + TextView
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 44, width: container.bounds.width, height: container.bounds.height - 44))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = content
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scrollView.documentView = textView
        container.addSubview(scrollView)

        // Bottom bar
        let cancelBtn = NSButton(title: "取消", target: nil, action: nil)
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: container.bounds.width - 230, y: 8, width: 70, height: 28)
        cancelBtn.autoresizingMask = [.minXMargin]

        let saveBtn = NSButton(title: "保存", target: nil, action: nil)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: container.bounds.width - 150, y: 8, width: 70, height: 28)
        saveBtn.autoresizingMask = [.minXMargin]

        let reloadBtn = NSButton(title: "保存并重载", target: nil, action: nil)
        reloadBtn.bezelStyle = .rounded
        reloadBtn.frame = NSRect(x: container.bounds.width - 150, y: 8, width: 130, height: 28)
        reloadBtn.autoresizingMask = [.minXMargin]

        // Position: Cancel ... Save&Reload
        cancelBtn.frame = NSRect(x: container.bounds.width - 220, y: 8, width: 70, height: 28)
        reloadBtn.frame = NSRect(x: container.bounds.width - 142, y: 8, width: 130, height: 28)
        container.addSubview(cancelBtn)
        container.addSubview(reloadBtn)

        // Capture weak references
        cancelBtn.target = self
        reloadBtn.target = self

        // Use a simple class to hold references for the actions
        class ConfigEditorContext {
            let window: NSWindow
            let textView: NSTextView
            let configPath: String
            weak var controller: StatusBarController?
            init(window: NSWindow, textView: NSTextView, configPath: String, controller: StatusBarController?) {
                self.window = window
                self.textView = textView
                self.configPath = configPath
                self.controller = controller
            }
            @objc func cancel(_ sender: Any) { window.close() }
            @objc func saveAndReload(_ sender: Any) {
                try? textView.string.write(toFile: configPath, atomically: true, encoding: .utf8)
                controller?.config.load()
                controller?.setupStatusItem()
                window.close()
            }
        }

        let ctx = ConfigEditorContext(window: w, textView: textView, configPath: configPath, controller: self)
        objc_setAssociatedObject(w, "configEditorCtx", ctx, .OBJC_ASSOCIATION_RETAIN)
        cancelBtn.target = ctx
        cancelBtn.action = #selector(ConfigEditorContext.cancel(_:))
        reloadBtn.target = ctx
        reloadBtn.action = #selector(ConfigEditorContext.saveAndReload(_:))

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = config.localPath
        if path.isEmpty { path = "\(home)/AIIA-RcloneSync" }
        path = path.replacingOccurrences(of: "$HOME", with: home)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func changeSyncFolder(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.title = "选择本地同步目录"
        panel.message = "选择用于与云存储同步的本地文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        // Set initial directory to current localPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var currentPath = config.localPath
        if currentPath.isEmpty { currentPath = "\(home)/CloudSync" }
        currentPath = currentPath.replacingOccurrences(of: "$HOME", with: home)
        panel.directoryURL = URL(fileURLWithPath: currentPath)

        NSApp.activate(ignoringOtherApps: true)
        let result = panel.runModal()
        guard result == .OK, let url = panel.url else { return }

        let newPath = url.path
        if newPath == currentPath { return }  // Same folder, no change

        // Confirmation dialog
        let alert = NSAlert()
        alert.messageText = "确认更改同步目录"
        alert.informativeText = """
        旧目录: \(currentPath)
        新目录: \(newPath)

        ⚠️ 旧目录中的文件不会被删除或移动。
        更改后建议执行「重新初始化同步」以建立新的同步基准。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确认更改")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        config.localPath = newPath
        config.save()
        buildMenu()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc private func toggleRemoteAction(_ sender: NSMenuItem) {
        guard let remoteName = sender.representedObject as? String else { return }
        config.toggleRemote(remoteName)
        config.load()
        setupScheduledTimers()  // Reschedule for new remote set
        setupStatusItem()

        // If now >1 remote and no rules file, prompt
        if config.activeRemotes.count > 1 && !SyncRulesManager.shared.hasRules {
            let alert = NSAlert()
            alert.messageText = "\u{26A1} \u{68C0}\u{6D4B}\u{5230}\u{591A}\u{4E2A}\u{4E91}\u{5B58}\u{50A8}"
            alert.informativeText = "\u{662F}\u{5426}\u{914D}\u{7F6E}\u{540C}\u{6B65}\u{89C4}\u{5219}\u{FF1F}\u{53EF}\u{4E3A}\u{4E0D}\u{540C}\u{5B50}\u{76EE}\u{5F55}\u{6307}\u{5B9A}\u{540C}\u{6B65}\u{5230}\u{54EA}\u{4E9B}\u{4E91}\u{5B58}\u{50A8}\u{3002}\n\n\u{9ED8}\u{8BA4}\u{5168}\u{90E8}\u{76EE}\u{5F55}\u{540C}\u{6B65}\u{5230}\u{6240}\u{6709}\u{4E91}\u{5B58}\u{50A8}\u{3002}"
            alert.addButton(withTitle: "\u{7ACB}\u{5373}\u{914D}\u{7F6E}")
            alert.addButton(withTitle: "\u{7A0D}\u{540E}\u{914D}\u{7F6E}")
            if alert.runModal() == .alertFirstButtonReturn {
                openSyncRulesWindow()
            }
        }
    }

    @objc private func openSyncRules(_ sender: NSMenuItem) {
        openSyncRulesWindow()
    }

    private var rulesWindow: SyncRulesWindow?

    private func openSyncRulesWindow() {
        rulesWindow = SyncRulesWindow(config: config) { [weak self] in
            self?.buildMenu()
        }
        rulesWindow?.show()
    }

    @objc private func runSetup(_ sender: NSMenuItem) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let setupScript = "\(home)/OneDrive/Tools/rclone-sync-mac/setup.sh"
        let appleScript = """
            tell application "Terminal"
                activate
                do script "\(setupScript)"
            end tell
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", appleScript]
        try? task.run()
    }

    // MARK: - Run Sync

    /// Sync all active remotes — skip those already syncing, notify user
    private func syncAllRemotes(extraArgs: [String] = []) {
        let remotes = config.activeRemotes
        guard !remotes.isEmpty else { return }

        var launched: [String] = []
        var skipped: [String] = []

        for remote in remotes {
            let remoteName = remote.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if let rs = remoteStatuses[remoteName], rs.status == "syncing" {
                skipped.append(remoteName)
            } else {
                launched.append(remoteName)
            }
        }

        // Launch non-syncing remotes
        for remoteName in launched {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.runSyncForRemote(remoteName, extraArgs: extraArgs)
            }
        }

        // Notify user about the result
        if !skipped.isEmpty {
            let skippedList = skipped.joined(separator: ", ")
            let launchedList = launched.isEmpty ? "无" : launched.joined(separator: ", ")
            let msg: String
            if launched.isEmpty {
                msg = "所有云存储都在同步中，本次操作已跳过"
            } else {
                msg = "已启动: \(launchedList)\n跳过(同步中): \(skippedList)"
            }
            notify("Cloud Sync", msg)
        }
    }

    /// macOS notification helper
    private func notify(_ title: String, _ message: String) {
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", "display notification \"\(message)\" with title \"\(title)\""]
        try? proc.run()
    }

    /// Run sync.sh for a single remote
    /// Shared launch helper — records PID and waits for completion
    private func launchSync(for remote: String, extraArgs: [String]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = [self.syncScriptPath, "--remote=\(remote):"] + extraArgs
            task.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path
            ]
            do {
                try task.run()
                let pid = task.processIdentifier
                DispatchQueue.main.async { self.trackedPIDs.insert(pid) }
                task.waitUntilExit()
                DispatchQueue.main.async {
                    self.trackedPIDs.remove(pid)
                    self.loadStatus()
                }
            } catch {
                DispatchQueue.main.async { self.loadStatus() }
            }
        }
    }

    private func runSyncForRemote(_ remote: String, extraArgs: [String]) {
        // Kill only this remote's existing sync
        killSyncFor(remote: remote)
        launchSync(for: remote, extraArgs: extraArgs)
    }
}
