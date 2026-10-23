# Contributing to ChargeKit

## Getting started

1. **Prerequisites**: macOS 13+, Xcode Command Line Tools (Swift 6+), Apple Silicon MacBook
2. **Clone & build**:
   ```bash
   git clone https://github.com/YOUR_USERNAME/ChargeKit.git
   cd ChargeKit
   swift build -c release
   ```
3. **Run tests** (must all pass before submitting):
   ```bash
   swift run policy-tests
   ```
4. **Install the helper** for end-to-end testing:
   ```bash
   sudo ./scripts/install-helper.sh
   ```

## Project structure

| Target | Purpose |
|--------|---------|
| `ChargeKitCore` | Pure decision logic (policy, scheduling, calibration) — no I/O, fully unit-tested |
| `SMCKit` | AppleSMC IOKit client (read/write) |
| `ChargeKitHelper` | Root LaunchDaemon for privileged SMC writes |
| `ChargeKitApp` | SwiftUI menu-bar app + settings window |
| `smcctl` | CLI debug tool |
| `PolicyTests` | Test runner (no XCTest dependency; zero-dep `check()` assertions) |

## Guidelines

- **Tests required**: every change to `ChargeKitCore` must come with assertions in `PolicyTests`
- **Zero warnings**: the build must produce no compiler warnings
- **Public APIs only**: no private frameworks, no reverse-engineered interfaces in shipped code
- **Safety first**: any code that can leave the machine on battery must have a recovery path (see `restoreAndExit` in the helper)
- **Comments explain why, not what**: the codebase uses inline comments for constraints and design decisions, not narration

## Submitting changes

1. Create a feature branch from `main`
2. Make your changes with tests
3. Ensure `swift build -c release` has zero warnings and `swift run policy-tests` passes
4. Open a pull request with a clear description of what changed and why

## Testing on real hardware

Some behaviors (SMC writes, sleep/wake, MagSafe LED) can only be verified on real Apple Silicon MacBooks. If you're contributing changes that affect these paths, please describe your testing methodology in the PR.
