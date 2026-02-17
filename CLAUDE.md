# VibeLimitApp

macOS menu bar app that shows Claude usage as a pikanyan nyan cat progress bar.

## What it does

- Displays an animated pikanyan gif in the macOS menu bar as a progress bar
- The cat's position represents 5-hour session utilization (0–100%)
- Rainbow trail (stretched from the gif's left edge) fills behind the cat
- Click the menu bar item to see: session/weekly usage % with ▰▱ progress bars, session resets in h/m, weekly resets in days
- Usage refreshes every 60 seconds and on menu open
- On auth/token errors, shows a "Run: claude auth login" menu item that opens Terminal to run the command

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
- Endpoint: `GET https://api.anthropic.com/api/oauth/usage`
- Header: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`
- Response: `{ "five_hour": { "utilization": 37.0, "resets_at": "..." }, "seven_day": { ... } }`
- Utilization is a percentage (0–100), resets_at is ISO 8601 with fractional seconds
- Error handling: 401/403 → auth error (prompts login), network errors and parse errors shown in menu
- On auth error, cached token is cleared; next refresh re-reads from keychain to auto-recover after login

### OAuth token
- Read from macOS Keychain via `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`
- Shelling out to the `security` CLI avoids repeated Keychain access prompts (the Security framework prompts on every rebuild since unsigned binaries get new identities)
- The keychain entry is a JSON blob; token is at `claudeAiOauth.accessToken`

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
- Menu shows ❓ per session (project folder name) with "Clear notifications" button
- `flash-notify.swift` helper reads session_id + cwd from hook JSON stdin and posts the distributed notification
- Claude Code hooks:
  - Flash on: `Notification`
  - Flash off: `Stop`, `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`

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
