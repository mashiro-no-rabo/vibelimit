# VibeLimitApp

macOS menu bar app that shows Claude usage as a pikanyan nyan cat progress bar.

## What it does

- Displays an animated pikanyan gif in the macOS menu bar as a progress bar
- The cat's position represents 5-hour session utilization (0–100%)
- Rainbow trail (stretched from the gif's left edge) fills behind the cat
- Click the menu bar item to see: session/weekly usage % with ▰▱ progress bars, session resets in h/m, weekly resets in days
- Usage refreshes every 60 seconds and on menu open
- Requires Claude Desktop to be logged in (reads its cookies for API access)
- On auth errors, shows an "Open Claude Desktop to log in" menu item

## Tech stack

- Swift (SPM executable), macOS 13+
- AppKit for the menu bar (NSStatusItem with custom NSView subview)
- No SwiftUI, no Xcode project — just `swift build`

## Project structure

```
Package.swift                              # SPM manifest
Sources/VibeLimitApp/main.swift            # All app code (single file)
Sources/VibeLimitApp/Resources/pikanyan.gif # Animated gif from vscode-nyan-cat
flash-notify.swift                         # Helper script for Claude Code hooks
com.vibelimit.app.plist                    # LaunchAgent plist for launchctl
README.md                                  # Build & launch setup docs
.gitignore
```

## Key implementation details

### GIF animation
- Frames extracted via `CGImageSourceCreateImageAtIndex` from ImageIO
- Frame durations read from GIF properties
- Animated at ~30fps via a Timer

### Usage API
- Endpoint: `GET https://claude.ai/api/organizations/{orgId}/usage`
- Auth: `sessionKey` and `lastActiveOrg` cookies from Claude Desktop
- Response: `{ "five_hour": { "utilization": 37.0, "resets_at": "..." }, "seven_day": { ... } }`
- Utilization is a percentage (0–100), resets_at is ISO 8601 with fractional seconds
- Error handling: 401/403 → auth error (prompts login), 429 → rate limited, network/parse errors shown in menu

### Claude Desktop cookies
- Reads encrypted Chromium cookies from `~/Library/Application Support/Claude/Cookies` (SQLite)
- Decryption key: macOS Keychain item "Claude Safe Storage", derived via PBKDF2 (salt "saltysalt", 1003 iterations, 16-byte key)
- AES-128-CBC decryption (IV = 16 spaces), strip 32-byte prefix from plaintext
- Shelling out to `/usr/bin/security` CLI avoids repeated Keychain access prompts (the Security framework prompts on every rebuild since unsigned binaries get new identities)
- Extracts `sessionKey` (auth) and `lastActiveOrg` (org ID for API URL)

### Menu bar view
- NSStatusItem with length 150px
- Custom NyanProgressView added as subview of statusItem.button
- Cat position: at 0% the tail (~35% of gif) is clipped off the left edge; at 100% the full cat sits at the right edge
- Rainbow trail: leftmost 1px column of the gif stretched horizontally behind the cat
- No dock icon: `app.setActivationPolicy(.accessory)`

### Flash notification
- Pulsing white overlay (1s sine wave cycle) triggered via `DistributedNotificationCenter`
- `com.vibelimit.flash.on` starts the flash, `com.vibelimit.flash.off` stops it
- Session ID tracking: each Claude session's flash is tracked independently; flash only stops when all sessions have cleared
- Menu shows notifications at the top: "Clear notifications" button followed by ❓ per session (project folder name)
- Clicking the menu bar item dismisses flashing; new flash-on notifications resume it
- Tracks `lastFlashTime` and `lastMenuClickTime` for dismiss/resume logic
- `flash-notify.swift` helper reads session_id + cwd from hook JSON stdin and posts the distributed notification
- Claude Code hooks:
  - Flash on: `Notification` (matchers: `permission_prompt`, `idle_prompt`)
  - Flash off: `Stop`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`

## Build & run

```sh
swift build
.build/debug/VibeLimitApp &
```

### LaunchAgent (run via launchctl)

```sh
cp com.vibelimit.app.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.vibelimit.app.plist
```

To reload after a build: `launchctl unload ~/Library/LaunchAgents/com.vibelimit.app.plist && launchctl load ~/Library/LaunchAgents/com.vibelimit.app.plist`

**Always reload the app after building.**

To stop: `launchctl unload ~/Library/LaunchAgents/com.vibelimit.app.plist`

## Pikanyan gif

Source: `../vscode-nyan-cat/src/imgs/pikanyan.gif` (104x46 pixels, animated GIF)
