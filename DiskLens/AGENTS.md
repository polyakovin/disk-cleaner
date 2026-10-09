# DiskLens

- Native macOS 14+ application. Swift Package Manager, Swift 5.9+; no external dependencies.
- `DiskLensCore` contains the POSIX metadata scanner, report generation and agent transports. It must not import SwiftUI or AppKit.
- `DiskLens` contains UI, Finder integration and Keychain storage. `disklens-cli` exposes the scanner for terminal use and verification.
- Scanner never reads file contents or follows symlinks; stays on the starting filesystem, counts hard links once, marks inaccessible and interrupted scans as partial. Retain bounded summaries, not millions of file nodes.
- Scanning runs off the main thread. Cancellation must stop promptly and retain a visibly partial report.
- Agent integration submits report metadata only on an explicit user action. No cleanup executor. Never store API keys in UserDefaults, exports or Git. Codex preset uses read-only mode and disables user hooks via `--ignore-user-config`.
- Canonical verification: `swift test`, then `swift build -c release`. `scripts/build-app.sh` builds and ad-hoc signs a universal `.app`; test the packaged application before delivering.
- `README.md` describes setup, provider connection and measurement limits. Keep session history out of this file.
