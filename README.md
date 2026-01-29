# Happy Manager

A macOS menu bar app to manage multiple Happy instances across your dev folders.

## Features

- **Menu Bar Interface**: Lives in your menu bar for quick access
- **Multi-Folder Support**: Add multiple dev folders and run Happy in each
- **Instance Count**: Configure how many Happy instances to run per folder (1-10)
- **Auto-Restart**: Automatically restarts crashed instances (up to 3 attempts)
- **Launch at Login**: Optionally start Happy Manager when your Mac boots
- **Status Monitoring**: Visual indicators show which instances are running

## Requirements

- **macOS 13.0+** (Ventura or later)
- **Node.js** via NVM at `~/.nvm/versions/node/v24.3.0/bin`
- **Happy CLI** installed globally (`npm install -g happy-coder`)

## Building

1. Open Terminal and navigate to this directory
2. Run the build script:
   ```bash
   chmod +x build.sh
   ./build.sh
   ```

Or open `HappyManager.xcodeproj` in Xcode and build manually (⌘B).

## Installation

1. Copy `HappyManager.app` to `/Applications`
2. Double-click to open
3. If macOS blocks it, go to **System Settings > Privacy & Security** and click "Open Anyway"
4. The app will appear in your menu bar with a 😊 icon

## Usage

1. Click the menu bar icon to open the control panel
2. Click **Add Folder** to select your dev folders
3. Use the stepper (×1, ×2, etc.) to set instance count per folder
4. Toggle folders on/off with the switch
5. Enable **Launch at Login** to start automatically

## Configuration

Config is stored at:
```
~/Library/Application Support/HappyManager/config.json
```

## Command Run

Each instance runs:
```bash
happy --permission-mode bypassPermissions
```

From the selected folder as the working directory.

## Notes

- **Orphan Cleanup**: On startup, kills any leftover Happy processes from previous runs
- **Log Management**: Automatically cleans up Happy logs older than 1 hour
- **Process Tree**: Properly terminates child processes when stopping instances
