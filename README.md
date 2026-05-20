# VibeLimitApp

macOS menu bar app that shows your Claude 5-hour session utilization as a percentage.

The menu bar title is padded to a consistent 4-character width (e.g. `  0%`, ` 37%`, `100%`) using monospaced digits and figure-space padding, so it doesn't jitter as the value changes. Click the menu bar item to see session/weekly usage bars and reset times.

Requires **Claude Desktop** to be logged in — usage data is read via Claude Desktop's session cookies.

## Build

```sh
swift build
```

## Run manually

```sh
.build/debug/VibeLimitApp &
```

## Run via LaunchAgent

Copy the plist to LaunchAgents:

```sh
cp com.vibelimit.app.plist ~/Library/LaunchAgents/
```

Edit the binary path in the plist if needed, then load it:

```sh
launchctl load ~/Library/LaunchAgents/com.vibelimit.app.plist
```

The app will now start on login and restart if it crashes.

To reload after a rebuild:

```sh
launchctl unload ~/Library/LaunchAgents/com.vibelimit.app.plist && launchctl load ~/Library/LaunchAgents/com.vibelimit.app.plist
```

To stop:

```sh
launchctl unload ~/Library/LaunchAgents/com.vibelimit.app.plist
```
