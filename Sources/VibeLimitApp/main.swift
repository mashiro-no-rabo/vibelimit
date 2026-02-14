import AppKit
import ImageIO

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

func readOAuthToken() -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice

    guard (try? proc.run()) != nil else { return nil }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { return nil }

    return token
}

func fetchUsage(token: String, completion: @escaping (UsageData?) -> Void) {
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
        completion(nil)
        return
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    URLSession.shared.dataTask(with: request) { data, _, _ in
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fiveHour = json["five_hour"] as? [String: Any],
              let sevenDay = json["seven_day"] as? [String: Any],
              let fiveUtil = fiveHour["utilization"] as? Double,
              let fiveReset = fiveHour["resets_at"] as? String,
              let sevenUtil = sevenDay["utilization"] as? Double,
              let sevenReset = sevenDay["resets_at"] as? String,
              let fiveDate = isoFormatter.date(from: fiveReset),
              let sevenDate = isoFormatter.date(from: sevenReset)
        else {
            completion(nil)
            return
        }

        completion(UsageData(
            fiveHour: UsageWindow(utilization: fiveUtil, resetsAt: fiveDate),
            sevenDay: UsageWindow(utilization: sevenUtil, resetsAt: sevenDate)
        ))
    }.resume()
}

// MARK: - Nyan Progress View

class NyanProgressView: NSView {
    var progress: CGFloat = 0
    var catFrames: [GIFFrame] = []
    var currentFrameIndex: Int = 0
    private var frameDurationAccumulator: TimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    func loadFrames(from url: URL) {
        catFrames = extractGIFFrames(from: url)
    }

    func advanceFrame(dt: TimeInterval) {
        guard !catFrames.isEmpty else { return }
        frameDurationAccumulator += dt
        let currentDuration = catFrames[currentFrameIndex].duration
        if frameDurationAccumulator >= currentDuration {
            frameDurationAccumulator -= currentDuration
            currentFrameIndex = (currentFrameIndex + 1) % catFrames.count
        }
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var nyanView: NyanProgressView!
    var animationTimer: Timer?
    var usageTimer: Timer?
    var latestUsage: UsageData?
    var oauthToken: String?

    // Menu items we update dynamically
    var fiveHourItem: NSMenuItem!
    var fiveHourResetItem: NSMenuItem!
    var sevenDayItem: NSMenuItem!
    var sevenDayResetItem: NSMenuItem!

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

        // Build menu
        let menu = NSMenu()
        menu.autoenablesItems = false

        fiveHourItem = NSMenuItem(title: "Current Session: ---%", action: nil, keyEquivalent: "")

        menu.addItem(fiveHourItem)

        fiveHourResetItem = NSMenuItem(title: "  Resets in: ---", action: nil, keyEquivalent: "")

        menu.addItem(fiveHourResetItem)

        menu.addItem(NSMenuItem.separator())

        sevenDayItem = NSMenuItem(title: "Weekly: ---%", action: nil, keyEquivalent: "")

        menu.addItem(sevenDayItem)

        sevenDayResetItem = NSMenuItem(title: "  Resets in: ---", action: nil, keyEquivalent: "")

        menu.addItem(sevenDayResetItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        // Read token and fetch usage
        oauthToken = readOAuthToken()
        refreshUsage()

        // Refresh usage every 60 seconds
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }

        // Animation timer at ~30fps
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.nyanView.advanceFrame(dt: 1.0 / 30.0)
            self.nyanView.needsDisplay = true
        }
    }

    func refreshUsage() {
        guard let token = oauthToken else { return }

        fetchUsage(token: token) { [weak self] usage in
            DispatchQueue.main.async {
                guard let self = self, let usage = usage else { return }
                self.latestUsage = usage

                // Update progress bar to show 5h utilization
                let util = CGFloat(usage.fiveHour.utilization / 100.0)
                self.nyanView.progress = min(max(util, 0), 1)

                // Update menu items
                self.fiveHourItem.title = String(format: "Current Session: %.0f%%", usage.fiveHour.utilization)
                self.fiveHourResetItem.title = "  Resets in: \(formatTimeUntil(usage.fiveHour.resetsAt))"
                self.sevenDayItem.title = String(format: "Weekly: %.0f%%", usage.sevenDay.utilization)
                let resetFmt = DateFormatter()
                resetFmt.dateFormat = "yyyy-MM-dd HH:mm"
                self.sevenDayResetItem.title = "  Resets at: \(resetFmt.string(from: usage.sevenDay.resetsAt))"
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
