# Repository Guidelines

## Project Structure & Module Organization

This is a Swift Package Manager macOS project. Source lives in `Sources/`, organized by target:

- `Sources/ChargeKitCore` — pure policy, scheduling, and calendar logic; no I/O.
- `Sources/SMCKit` — AppleSMC IOKit client and SMC command support.
- `Sources/ChargeKitApp` — SwiftUI menu-bar and settings application.
- `Sources/ChargeKitHelper` — privileged LaunchDaemon and XPC service.
- `Sources/smcctl` — debugging CLI.
- `Sources/PolicyTests` — zero-dependency policy test runner.

Shared shell scripts and app assets are in `scripts/`; build output is in `.build/` and `build/`.

## Build, Test, and Development Commands

```bash
swift build                 # Debug build for all targets
swift build -c release      # Release build; must produce zero warnings
swift run policy-tests      # Run the required policy and scheduling assertions
./scripts/build-app.sh      # Build and launch ChargeKit.app
sudo ./scripts/install-helper.sh       # Install the privileged helper
sudo ./scripts/uninstall-helper.sh     # Remove the helper
```

Use `.build/release/smcctl` for manual SMC and helper debugging.

## Coding Style & Naming Conventions

- Use Swift 5 language mode with four-space indentation and standard Swift naming (`UpperCamelCase` for types, `lowerCamelCase` for members).
- Keep `ChargeKitCore` free of I/O so it remains directly testable.
- Use public macOS APIs only; do not depend on private frameworks or reverse-engineered interfaces.
- Prefer comments that explain constraints or design decisions rather than narrating code.
- Changes that can leave the machine on battery must include a reliable recovery path.

## Testing Guidelines

Every `ChargeKitCore` behavior change requires assertions in `Sources/PolicyTests/main.swift`. Use the existing `check()` pattern, keep tests deterministic, and run `swift run policy-tests` before submitting. Hardware-only behavior should be described in the pull request, including the tested MacBook and macOS version.

## Commit & Pull Request Guidelines

History uses short, imperative subjects, often with conventional prefixes such as `ci:`. Keep commits focused and describe the user-visible or architectural change.

Pull requests should include a clear summary of what changed and why, notes on safety impacts, linked issues where applicable, and hardware testing details. Confirm that both `swift build -c release` and `swift run policy-tests` pass.

## Security & Configuration Tips

Do not broaden the helper’s SMC write whitelist without strong justification and review. Treat privileged code, discharge sessions, and crash/termination recovery as security-sensitive paths.
