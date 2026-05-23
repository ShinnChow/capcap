@CLAUDE.md

## Packaging Lessons

- SwiftPM target resources are not automatically present in the hand-assembled
  `.app` bundle. If any package target declares `resources:` in `Package.swift`
  or code uses `Bundle.module`, update both `scripts/bundle.sh` and the release
  workflow to copy the generated `<package>_<target>.bundle` into
  `capcap.app/Contents/Resources/`.
- Treat a missing SwiftPM resource bundle as a release-blocking error, not a
  runtime fallback. The failure may only surface when a UI path first touches
  `Bundle.module`, such as the PermissionFlow authorization panel.
- After packaging changes, verify the final `.app` contents directly with
  `find build/capcap.app/Contents/Resources -maxdepth 2 -name '*.bundle'` and,
  for release builds, confirm the universal app still contains both `arm64` and
  `x86_64` slices.
