import AppKit
import CommonCrypto
import ImageIO
import SQLite3

// MARK: - GIF Frame Extraction

struct GIFFrame {
    let image: NSImage
    let duration: TimeInterval
}

func extractGIFFrames(from url: URL) -> [GIFFrame] {
    guard let data = try? Data(contentsOf: url),
          let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return []
    }

    let count = CGImageSourceGetCount(source)
    var frames: [GIFFrame] = []

    for i in 0..<count {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
        let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let duration = (gifProperties?[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval)
            ?? (gifProperties?[kCGImagePropertyGIFDelayTime] as? TimeInterval)
            ?? 0.1

        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let nsImage = NSImage(cgImage: cgImage, size: size)
        frames.append(GIFFrame(image: nsImage, duration: max(duration, 0.02)))
    }

    return frames
}

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

// MARK: - Nyan Progress View

class NyanProgressView: NSView {
    var progress: CGFloat = 0
    var catFrames: [GIFFrame] = []
    var currentFrameIndex: Int = 0
    private var frameDurationAccumulator: TimeInterval = 0
    private var lastTickTime: CFTimeInterval = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    func loadFrames(from url: URL) {
        catFrames = extractGIFFrames(from: url)
    }

    /// Advances GIF frame using real elapsed time. Returns true if the displayed frame changed.
    func advanceFrame() -> Bool {
        guard !catFrames.isEmpty else { return false }
        let now = CACurrentMediaTime()
        let dt: TimeInterval
        if lastTickTime == 0 {
            dt = 0
        } else {
            dt = min(now - lastTickTime, 0.5) // cap to avoid jumps after sleep
        }
        lastTickTime = now

        let prevIndex = currentFrameIndex
        frameDurationAccumulator += dt
        let currentDuration = catFrames[currentFrameIndex].duration
        if frameDurationAccumulator >= currentDuration {
            frameDurationAccumulator -= currentDuration
            currentFrameIndex = (currentFrameIndex + 1) % catFrames.count
        }
        return currentFrameIndex != prevIndex
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !catFrames.isEmpty else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()

        let frame = catFrames[currentFrameIndex]
        let imgSize = frame.image.size
        let catHeight: CGFloat = bounds.height
        let scale = catHeight / imgSize.height
        let catWidth: CGFloat = imgSize.width * scale

        // At 0%, clip just the tail (left ~35% of the gif), not the whole cat
        let tailClip: CGFloat = catWidth * 0.35
        let catX = progress * (bounds.width - catWidth + tailClip) - tailClip
        let catY: CGFloat = 0

        // Draw the rainbow trail by stretching the leftmost 1px column of the gif
        let trailEnd = catX + catWidth * 0.15
        if trailEnd > 0 {
            let sourceSlice = NSRect(x: 0, y: 0, width: 1, height: imgSize.height)
            let trailRect = NSRect(x: 0, y: catY, width: trailEnd, height: catHeight)
            frame.image.draw(in: trailRect, from: sourceSlice, operation: .sourceOver, fraction: 1.0)
        }

        // Draw the cat
        let catRect = NSRect(x: catX, y: catY, width: catWidth, height: catHeight)
        frame.image.draw(in: catRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Badge View

class BadgeView: NSView {
    var count: Int = 0 {
        didSet {
            isHidden = count <= 0
            if count > 0 { startFlash() } else { stopFlash() }
            needsDisplay = true
        }
    }

    private var flashTimer: Timer?
    private var flashPhase: CGFloat = 0
    private var flashAlpha: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func startFlash() {
        guard flashTimer == nil else { return }
        flashPhase = 0
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.flashPhase += 1.0 / 30.0
            self.flashAlpha = CGFloat((sin(self.flashPhase * 2 * .pi) + 1) / 2) * 0.6 + 0.4
            self.needsDisplay = true
        }
    }

    func stopFlash() {
        flashTimer?.invalidate()
        flashTimer = nil
        flashAlpha = 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }

        let badgeText = "\(count)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let textSize = (badgeText as NSString).size(withAttributes: attrs)
        let badgeHeight: CGFloat = 18
        let badgeWidth = max(textSize.width + 8, badgeHeight)
        let badgeRect = NSRect(
            x: bounds.width - badgeWidth,
            y: (bounds.height - badgeHeight) / 2,
            width: badgeWidth,
            height: badgeHeight
        )
        // Use the same foreground color macOS uses for menu bar icons
        (NSColor.controlTextColor.withAlphaComponent(flashAlpha)).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()
        let textRect = NSRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        (badgeText as NSString).draw(in: textRect, withAttributes: attrs)
    }
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var nyanView: NyanProgressView!
    var badgeView: BadgeView!
    var animationTimer: Timer?
    var usageTimer: Timer?
    var latestUsage: UsageData?
    var flashingSessions: [String: String] = [:]  // session_id -> display name

    // Menu items we update dynamically
    var fiveHourBarItem: NSMenuItem!
    var fiveHourItem: NSMenuItem!
    var fiveHourResetItem: NSMenuItem!
    var sevenDayBarItem: NSMenuItem!
    var sevenDayItem: NSMenuItem!
    var sevenDayResetItem: NSMenuItem!
    var loginItem: NSMenuItem!

    // Flash notification menu items (inserted dynamically)
    var flashSeparatorItem: NSMenuItem!
    var clearAllItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let barWidth: CGFloat = 150

        statusItem = NSStatusBar.system.statusItem(withLength: barWidth)
        statusItem.autosaveName = "!VibeLimitNyanCat"

        guard let button = statusItem.button else { return }

        nyanView = NyanProgressView(frame: button.bounds)
        nyanView.autoresizingMask = [.width, .height]
        button.addSubview(nyanView)

        if let gifURL = Bundle.module.url(forResource: "pikanyan", withExtension: "gif") {
            nyanView.loadFrames(from: gifURL)
        }

        badgeView = BadgeView(frame: button.bounds)
        badgeView.autoresizingMask = [.width, .height]
        button.addSubview(badgeView)

        // Build menu
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = menuContentWidth

        clearAllItem = NSMenuItem(title: "Clear notifications", action: #selector(clearAllFlash), keyEquivalent: "")
        clearAllItem.target = self
        clearAllItem.isHidden = true
        menu.addItem(clearAllItem)

        flashSeparatorItem = NSMenuItem.separator()
        flashSeparatorItem.isHidden = true
        menu.addItem(flashSeparatorItem)

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

        menu.delegate = self
        statusItem.menu = menu

        refreshUsage()

        // Refresh usage every 60 seconds
        usageTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
        usageTimer?.tolerance = 5
        RunLoop.current.add(usageTimer!, forMode: .common)

        // Animation timer at ~30fps with tolerance for energy efficiency
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.nyanView.advanceFrame() {
                self.nyanView.needsDisplay = true
            }
        }
        animationTimer?.tolerance = 0.005 // ~5ms tolerance lets macOS coalesce timer fires

        // Listen for distributed notifications to control flash
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleFlashOn),
            name: NSNotification.Name("com.vibelimit.flash.on"), object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleFlashOff),
            name: NSNotification.Name("com.vibelimit.flash.off"), object: nil
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        badgeView.stopFlash()
        rebuildFlashMenuItems()
    }

    private func parseFlashPayload(_ notification: Notification) -> (id: String, name: String)? {
        guard let jsonString = notification.object as? String,
              let data = jsonString.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let id = payload["id"] else { return nil }
        return (id, payload["name"] ?? id)
    }

    @objc func handleFlashOn(_ notification: Notification) {
        if let info = parseFlashPayload(notification) {
            flashingSessions[info.id] = info.name
        }
        updateBadge()
    }

    @objc func handleFlashOff(_ notification: Notification) {
        if let info = parseFlashPayload(notification) {
            flashingSessions.removeValue(forKey: info.id)
        }
        updateBadge()
    }

    @objc func clearAllFlash() {
        flashingSessions.removeAll()
        updateBadge()
    }

    private func updateBadge() {
        badgeView.count = flashingSessions.count
    }

    private func rebuildFlashMenuItems() {
        guard let menu = statusItem.menu else { return }

        // Remove old dynamic session items (tagged with 999)
        for item in menu.items where item.tag == 999 {
            menu.removeItem(item)
        }

        let hasNotifications = !flashingSessions.isEmpty
        flashSeparatorItem.isHidden = !hasNotifications
        clearAllItem.isHidden = !hasNotifications

        if hasNotifications {
            var insertIndex = menu.index(of: clearAllItem) + 1
            for (_, name) in flashingSessions.sorted(by: { $0.value < $1.value }) {
                let item = NSMenuItem()
                item.view = makeMenuItemView("❓ \(name)")
                item.tag = 999
                menu.insertItem(item, at: insertIndex)
                insertIndex += 1
            }
        }
    }

    @objc func openLogin() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func showError(_ message: String, isAuthError: Bool = false) {
        fiveHourBarItem.view = makeMenuItemView(styledMenuTitle(message))
        fiveHourItem.view = makeMenuItemView("")
        fiveHourResetItem.view = makeMenuItemView("")
        sevenDayBarItem.view = makeMenuItemView("")
        sevenDayItem.view = makeMenuItemView("")
        sevenDayResetItem.view = makeMenuItemView("")
        loginItem.isHidden = !isAuthError
        nyanView.progress = 0
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

                    // Update progress bar to show 5h utilization
                    let util = CGFloat(usage.fiveHour.utilization / 100.0)
                    self.nyanView.progress = min(max(util, 0), 1)

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
