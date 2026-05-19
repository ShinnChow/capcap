# capcap

macOS menu bar screenshot tool. Pure AppKit, Swift Package Manager, no third-party dependencies.

## Build & Run

After every code change, run the rebuild script to build, restart, and verify the app:

```bash
bash scripts/rebuild-and-open.sh
```

This script builds the app bundle, kills any running instance, launches the new build, and confirms it started.

## Project Structure

- `capcap/App/` — Entry point (`main.swift`, `AppDelegate.swift`, `Info.plist`)
- `capcap/Capture/` — Screen capture logic (ScreenCaptureKit, selection overlay)
- `capcap/Editor/` — Post-capture annotation editor
- `capcap/Trigger/` — Double-tap ⌘ key detection
- `capcap/UI/` — Status bar, toast, cursor chip
- `capcap/Settings/` — Settings dialog (startup + preferences)
- `capcap/Utilities/` — UserDefaults wrapper
- `scripts/` — Build and bundle scripts

## Key Rules

- **Always run `bash scripts/compile-check.sh` after modifying code** to verify the compile .
- No SwiftUI — this project uses AppKit exclusively with programmatic UI.
- No storyboards or XIBs.
- Minimum deployment target: macOS 14.0.

## Adding an Editor Tool

Whenever a new annotation/editor tool is added, it MUST also be wired into the
toolbar — a tool that isn't in `ToolbarLayout` never appears for the user.
Checklist:

- Add the `ToolbarItemID` case and update `editTool`, `symbolName`, `tooltip`,
  and the `kind` switch in `ToolbarLayout.swift`.
- Add the case to **both** `ToolbarLayout.canonicalOrder` and the `default`
  layout's `primary`/`side`/`hidden` buckets. A tool missing from
  `canonicalOrder` is invisible even though the enum case exists.
- Add the `tipXxx` localization key to `Defaults.swift` and to every
  `Resources/*.lproj/Localizable.strings` file.
- If the user has not told you where the tool should sit in the toolbar by
  default, **ask before placing it** — don't guess the position.
