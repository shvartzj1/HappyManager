# Happy Manager - Development Guide

## Project Overview

macOS menu bar application (SwiftUI) that manages multiple instances of the `happy` CLI tool across development folders. Runs instances with `--permission-mode bypassPermissions`.

## Architecture

```
HappyManager/
├── HappyManagerApp.swift    # Entry point, AppDelegate, menu bar setup
├── Models.swift             # FolderConfig, InstanceStatus, ConfigStore
├── ContentView.swift        # SwiftUI views (popover UI)
└── ProcessManager.swift     # Process lifecycle, PTY management
```

### Key Patterns

- **Singletons**: `ConfigStore.shared`, `ProcessManager.shared`
- **Reactive UI**: SwiftUI with `@ObservedObject` + `@Published`
- **Combine**: Config changes trigger process sync via `$folders.sink`
- **PTY**: Uses `openpty()` for proper terminal emulation

### Data Flow

```
User Action → ConfigStore.updateFolder() → $folders publisher
                                                ↓
                                    ProcessManager.syncInstances()
                                                ↓
                                    startInstance() with PTY → happy CLI
```

## Building

```bash
./build.sh
# Or: xcodebuild -project HappyManager.xcodeproj -scheme HappyManager -configuration Release
```

Output: `./build/Build/Products/Release/HappyManager.app`

## Key Files

| File | Purpose |
|------|---------|
| `HappyManager.entitlements` | Non-sandboxed for process management |
| `Info.plist` | LSUIElement=true (menu bar app, no dock icon) |
| `~/.happy/daemon.state.json` | External daemon port info |
| `~/Library/Application Support/HappyManager/config.json` | Persisted folder config |

## Code Conventions

### Swift Style
- Use `guard` for early returns
- Prefer `if let` over force unwrapping
- Use trailing closures for Combine/async

### Process Management
- Always use PTY pairs for CLI processes (not just pipes)
- Kill child processes recursively with `pgrep -P`
- Clean up logs when stopping instances

### UI Patterns
- Keep views small, extract subviews (FolderRow, InstanceRow, StatusBadge)
- Use computed properties for derived state (e.g., `runningCount`)
- Bindings for two-way config updates

## Common Tasks

### Adding a New Config Option
1. Add property to `FolderConfig` in Models.swift
2. Update `ConfigStore.save()`/`load()` if needed
3. Add UI control in `FolderRow`
4. Handle in `ProcessManager.startInstance()` if affects process

### Adding UI to Popover
1. Create new View struct in ContentView.swift
2. Use `@ObservedObject var configStore = ConfigStore.shared`
3. Use `@ObservedObject var processManager = ProcessManager.shared`

### Modifying Process Launch
- Edit `startInstance()` in ProcessManager.swift
- Command is in: `process.arguments = ["-i", "-l", "-c", "cd ... && exec happy ..."]`
- Environment setup is above the process.run() call

## Important Notes

- **Min macOS**: 13.0 (for SMAppService)
- **Not sandboxed**: Required for spawning external processes
- **NVM dependency**: Expects Node at `~/.nvm/versions/node/v24.3.0/bin`
- **Daemon API**: Uses HTTP POST to `127.0.0.1:{port}/list` for session info
- **Auto-restart**: Max 3 attempts on crash, 1-second delay between

## Testing

No automated tests currently. Manual testing:
1. Build and run app
2. Add a dev folder with happy installed
3. Verify instance starts (check Activity Monitor for `happy` process)
4. Test start/stop/restart controls
5. Test instance count stepper
6. Verify launch at login toggle

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Instance won't start | Check if `happy` is in PATH (NVM node version) |
| Orphan processes | App kills orphans on startup via daemon API |
| Logs filling disk | Auto-cleanup removes logs >1 hour old |
| PTY errors | Check file descriptor limits |
