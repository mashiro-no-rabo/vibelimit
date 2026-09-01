import AppKit
import CommonCrypto
import SQLite3

// MARK: - Keychain + Usage API

struct UsageWindow {
    let utilization: Double
    let resetsAt: Date
}

struct UsageData {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
}

struct ClaudeCookies {
    let sessionKey: String
    let orgId: String
}

func readClaudeCookies() -> ClaudeCookies? {
    // Get encryption password from keychain
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    proc.arguments = ["find-generic-password", "-s", "Claude Safe Storage", "-w"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { NSLog("VL: security exec failed"); return nil }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { NSLog("VL: security exit %d", proc.terminationStatus); return nil }
    let pwData = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let password = String(data: pwData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !password.isEmpty else { NSLog("VL: empty password"); return nil }

    // Derive AES-128 key via PBKDF2
    let salt = "saltysalt".data(using: .utf8)!
    var derivedKey = [UInt8](repeating: 0, count: 16)
    let status = CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2),
        password, password.utf8.count,
        [UInt8](salt), salt.count,
        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
        1003,
        &derivedKey, 16
    )
    guard status == kCCSuccess else { NSLog("VL: PBKDF2 failed"); return nil }

    // Open SQLite cookies database
    let cookiesPath = NSHomeDirectory() + "/Library/Application Support/Claude/Cookies"
    var db: OpaquePointer?
    guard sqlite3_open_v2(cookiesPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        NSLog("VL: sqlite open failed: %s", String(cString: sqlite3_errmsg(db)))
        return nil
    }
    defer { sqlite3_close(db) }

    func readCookie(name: String) -> String? {
        var stmt: OpaquePointer?
        let sql = "SELECT encrypted_value FROM cookies WHERE host_key LIKE '%claude.ai%' AND name = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("VL: prepare failed for %@", name)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            NSLog("VL: no row for %@", name)
            return nil
        }

        let blobPtr = sqlite3_column_blob(stmt, 0)
        let blobLen = Int(sqlite3_column_bytes(stmt, 0))
        guard let blobPtr = blobPtr, blobLen > 3 else { NSLog("VL: blob too short for %@", name); return nil }
        let encrypted = Data(bytes: blobPtr, count: blobLen)

        // Expect "v10" prefix
        guard encrypted.prefix(3) == Data("v10".utf8) else { NSLog("VL: no v10 prefix for %@", name); return nil }
        let ciphertext = [UInt8](encrypted.dropFirst(3))

        // AES-128-CBC with 16 spaces as IV
        let iv = [UInt8](repeating: 0x20, count: 16)
        var decrypted = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedLen = 0
        let cryptStatus = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            0, // no padding flag — we strip PKCS7 manually
            derivedKey, 16,
            iv,
            ciphertext, ciphertext.count,
            &decrypted, decrypted.count,
            &decryptedLen
        )
        guard cryptStatus == kCCSuccess else { NSLog("VL: decrypt failed %d for %@", cryptStatus, name); return nil }
        guard decryptedLen > 32 else { NSLog("VL: decrypted too short for %@", name); return nil }

        // Strip PKCS7 padding, then strip 32-byte prefix
        let padLen = Int(decrypted[decryptedLen - 1])
        let plaintext = Data(decrypted[0..<(decryptedLen - padLen)])
        guard plaintext.count > 32 else { NSLog("VL: plaintext too short for %@", name); return nil }
        return String(data: plaintext.dropFirst(32), encoding: .utf8)
    }

    guard let sessionKey = readCookie(name: "sessionKey"),
          let orgId = readCookie(name: "lastActiveOrg") else { return nil }
    return ClaudeCookies(sessionKey: sessionKey, orgId: orgId)
}

enum UsageError {
    case authError
    case networkError
    case parseError
    case rateLimited
}

enum UsageResult {
    case success(UsageData)
    case failure(UsageError)
}

func fetchUsage(cookies: ClaudeCookies, completion: @escaping (UsageResult) -> Void) {
    guard let url = URL(string: "https://claude.ai/api/organizations/\(cookies.orgId)/usage") else {
        completion(.failure(.networkError))
        return
    }

    var request = URLRequest(url: url)
    request.setValue("sessionKey=\(cookies.sessionKey); lastActiveOrg=\(cookies.orgId)", forHTTPHeaderField: "Cookie")
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    // Fallback formatter without fractional seconds
    let isoFormatterNoFrac = ISO8601DateFormatter()
    isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

    func parseDate(_ string: String) -> Date? {
        isoFormatter.date(from: string) ?? isoFormatterNoFrac.date(from: string)
    }

    URLSession.shared.dataTask(with: request) { data, response, error in
        if error != nil {
            completion(.failure(.networkError))
            return
        }

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                completion(.failure(.authError))
                return
            }
            if httpResponse.statusCode == 429 {
                completion(.failure(.rateLimited))
                return
            }
            if httpResponse.statusCode != 200 {
                completion(.failure(.networkError))
                return
            }
        }

        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fiveHour = json["five_hour"] as? [String: Any],
              let sevenDay = json["seven_day"] as? [String: Any],
              let fiveReset = fiveHour["resets_at"] as? String,
              let sevenReset = sevenDay["resets_at"] as? String,
              let fiveDate = parseDate(fiveReset),
              let sevenDate = parseDate(sevenReset)
        else {
            completion(.failure(.parseError))
            return
        }

        // Utilization may be null or missing; default to 0
        let fiveUtil = (fiveHour["utilization"] as? Double) ?? 0
        let sevenUtil = (sevenDay["utilization"] as? Double) ?? 0

        completion(.success(UsageData(
            fiveHour: UsageWindow(utilization: fiveUtil, resetsAt: fiveDate),
            sevenDay: UsageWindow(utilization: sevenUtil, resetsAt: sevenDate)
        )))
    }.resume()
}

// MARK: - ASCII Progress Bar

func asciiProgressBar(_ percent: Double, width: Int = 20) -> String {
    let clamped = min(max(percent, 0), 100)
    let filled = Int(round(clamped / 100.0 * Double(width)))
    let empty = width - filled
    return String(repeating: "▰", count: filled) + String(repeating: "▱", count: empty)
}

func styledMenuTitle(_ text: String) -> NSAttributedString {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    return NSAttributedString(string: text, attributes: [.font: font])
}

let menuContentWidth: CGFloat = 150

func makeMenuItemView(_ attributedString: NSAttributedString) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuContentWidth, height: 20))
    let textField = NSTextField(labelWithAttributedString: attributedString)
    textField.frame = NSRect(x: 14, y: 0, width: menuContentWidth - 28, height: 20)
    textField.lineBreakMode = .byTruncatingTail
    view.addSubview(textField)
    return view
}

func makeMenuItemView(_ text: String) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuContentWidth, height: 20))
    let textField = NSTextField(labelWithString: text)
    textField.font = NSFont.menuFont(ofSize: 0)
    textField.frame = NSRect(x: 14, y: 0, width: menuContentWidth - 28, height: 20)
    textField.lineBreakMode = .byTruncatingTail
    view.addSubview(textField)
    return view
}

// MARK: - Time Formatting

func formatTimeUntil(_ date: Date) -> String {
    let interval = date.timeIntervalSinceNow
    if interval <= 0 { return "now" }

    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60

    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

func formatDaysUntil(_ date: Date) -> String {
    let interval = date.timeIntervalSinceNow
    if interval <= 0 { return "now" }

    let days = Int(ceil(interval / 86400))
    if days == 1 { return "1 day" }
    return "\(days) days"
}

// MARK: - Status Bar Title

// Utilization is how much of the session budget is *used*, so the words
// describe how much headroom is left. Two-kanji words keep the menu bar
// width stable.
func headroomWord(percent: Double) -> String {
    let clamped = min(max(percent, 0), 100)
    switch clamped {
    case ..<34: return "余裕"
    case ..<67: return "半分"
    case ..<90: return "間近"
    default: return "限界"
    }
}

func statusBarTitle(percent: Double) -> NSAttributedString {
    let font = NSFont.systemFont(ofSize: 13, weight: .regular)
    return NSAttributedString(string: headroomWord(percent: percent), attributes: [.font: font])
}

func statusBarErrorTitle(_ text: String) -> NSAttributedString {
    let font = NSFont.systemFont(ofSize: 13, weight: .regular)
    return NSAttributedString(string: text, attributes: [.font: font])
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var usageTimer: Timer?
    var latestUsage: UsageData?

    // Menu items we update dynamically
    var fiveHourBarItem: NSMenuItem!
    var fiveHourItem: NSMenuItem!
    var fiveHourResetItem: NSMenuItem!
    var sevenDayBarItem: NSMenuItem!
    var sevenDayItem: NSMenuItem!
    var sevenDayResetItem: NSMenuItem!
    var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "!VibeLimitPercent"

        statusItem.button?.attributedTitle = statusBarErrorTitle("…")

        // Build menu
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = menuContentWidth

        fiveHourBarItem = NSMenuItem()
        fiveHourBarItem.view = makeMenuItemView(styledMenuTitle(asciiProgressBar(0, width: 15)))
        menu.addItem(fiveHourBarItem)

        fiveHourItem = NSMenuItem()
        fiveHourItem.view = makeMenuItemView("Session: ---%")
        menu.addItem(fiveHourItem)

        fiveHourResetItem = NSMenuItem()
        fiveHourResetItem.view = makeMenuItemView("Resets in ---")
        menu.addItem(fiveHourResetItem)

        menu.addItem(NSMenuItem.separator())

        sevenDayBarItem = NSMenuItem()
        sevenDayBarItem.view = makeMenuItemView(styledMenuTitle(asciiProgressBar(0, width: 15)))
        menu.addItem(sevenDayBarItem)

        sevenDayItem = NSMenuItem()
        sevenDayItem.view = makeMenuItemView("Weekly: ---%")
        menu.addItem(sevenDayItem)

        sevenDayResetItem = NSMenuItem()
        sevenDayResetItem.view = makeMenuItemView("Resets in ---")
        menu.addItem(sevenDayResetItem)

        menu.addItem(NSMenuItem.separator())

        loginItem = NSMenuItem(title: "Open Claude Desktop to log in", action: #selector(openLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.isHidden = true
        menu.addItem(loginItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshUsage), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        refreshUsage()

        // Refresh usage every 60 seconds
        usageTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
        usageTimer?.tolerance = 5
        RunLoop.current.add(usageTimer!, forMode: .common)
    }

    @objc func openLogin() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func showError(_ message: String, isAuthError: Bool = false) {
        statusItem.button?.attributedTitle = statusBarErrorTitle("Error")
        fiveHourBarItem.view = makeMenuItemView(styledMenuTitle(message))
        fiveHourItem.view = makeMenuItemView("")
        fiveHourResetItem.view = makeMenuItemView("")
        sevenDayBarItem.view = makeMenuItemView("")
        sevenDayItem.view = makeMenuItemView("")
        sevenDayResetItem.view = makeMenuItemView("")
        loginItem.isHidden = !isAuthError
    }

    @objc func refreshUsage() {
        // Read cookies from Claude Desktop's Chromium cookie store
        guard let cookies = readClaudeCookies() else {
            showError("Open Claude Desktop", isAuthError: true)
            return
        }

        fetchUsage(cookies: cookies) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                switch result {
                case .success(let usage):
                    self.loginItem.isHidden = true
                    self.latestUsage = usage

                    self.statusItem.button?.attributedTitle = statusBarTitle(percent: usage.fiveHour.utilization)

                    // Update menu items
                    self.fiveHourBarItem.view = makeMenuItemView(styledMenuTitle(asciiProgressBar(usage.fiveHour.utilization, width: 15)))
                    self.fiveHourItem.view = makeMenuItemView(String(format: "Session: %.0f%%", usage.fiveHour.utilization))
                    self.fiveHourResetItem.view = makeMenuItemView("Resets in \(formatTimeUntil(usage.fiveHour.resetsAt))")
                    self.sevenDayBarItem.view = makeMenuItemView(styledMenuTitle(asciiProgressBar(usage.sevenDay.utilization, width: 15)))
                    self.sevenDayItem.view = makeMenuItemView(String(format: "Weekly: %.0f%%", usage.sevenDay.utilization))
                    self.sevenDayResetItem.view = makeMenuItemView("Resets in \(formatDaysUntil(usage.sevenDay.resetsAt))")

                case .failure(.authError):
                    self.showError("Run: claude login")

                case .failure(.networkError):
                    self.showError("Network error")

                case .failure(.rateLimited):
                    self.showError("Rate limited")

                case .failure(.parseError):
                    self.showError("API error")
                }
            }
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
