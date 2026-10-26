# ChargeKit

A native macOS charge limiter that gives you full control over your MacBook's charging behavior — using only public APIs.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/Tests-198%20passed-brightgreen)

## What it does

ChargeKit limits how high your MacBook charges, extends battery lifespan, and provides detailed battery telemetry — all through a menu-bar popover and a native settings window.

| Feature | Description |
|---------|-------------|
| Charge limit | Stop charging at any level (50–100%) |
| Sailing mode | Let the battery drift in a range instead of pinning to one number |
| Heat protection | Pause charging when the battery gets too hot; resume when it cools |
| Discharge | Run on battery while plugged in, down to your target level |
| Automatic discharge | Discharge automatically when above your limit |
| Top-up | Charge to 100% once, then return to your limit |
| Calibration | Full charge → hold → discharge → restore cycle |
| Sleep-stop | Cut charging when the Mac sleeps; resume on wake |
| Prevent sleep | Keep the Mac awake while charging toward your limit |
| MagSafe LED | Green at limit, orange while charging, off on battery |
| Notifications | Limit reached, top-up done, discharge done, calibration done |
| Schedule | 7 action types × 7 repeat modes, with catch-up after sleep |
| Task history | Complete audit trail of every action, session, and state change |
| Battery info | Design capacity, health %, cycle count, temperature, live power flow |
| Hardware % | Toggle between macOS gauge and BMS-direct battery percentage |
| Clamshell discharge | Discharge works with lid closed (automatic sleep prevention) |
| Right-click menu | Menu-bar context menu: settings, about, and quit |

## How it works

ChargeKit communicates with the AppleSMC kernel driver via IOKit to read battery telemetry and control charging. A privileged helper daemon (installed via LaunchDaemon) performs the actual SMC writes.

**Key SMC registers used:**
- `CHTE` — charge switch (stop/start charging, adapter keeps powering the Mac)
- `CHIE` — adapter switch (physically disconnect wall power, for discharge)
- `BUIC` — battery percent (BMS-direct)
- `PDTR` — input power (W)
- `TB0T` — battery temperature (°C)
- `B0AV`/`B0AC` — battery voltage/current
- `ACLC` — MagSafe LED color

All reads are unprivileged; writes go through the root daemon with a whitelist of charge-control keys only.

## Requirements

- macOS 13 Ventura or later
- Apple Silicon MacBook (Intel path uses BCLM, untested)
- Xcode Command Line Tools (Swift 6+)

## Build & Install

```bash
git clone https://github.com/YOUR_USERNAME/ChargeKit.git
cd ChargeKit

# Build everything
swift build -c release

# Run the test suite (198 assertions)
swift run policy-tests

# Build and launch the app
./scripts/build-app.sh
open build/ChargeKit.app
```

The first launch installs the privileged helper from inside the app
bundle (one-time administrator prompt). A manual fallback is still
available:

```bash
sudo ./scripts/install-helper.sh
```

The helper daemon can be uninstalled at any time:

```bash
sudo ./scripts/uninstall-helper.sh
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│  ChargeKitApp (menu-bar + settings window)     │
│  ┌─────────────────┐  ┌──────────────────────┐ │
│  │ ChargeKitCore   │  │ SMCKit               │ │
│  │ (pure policy)   │  │ (SMC read/write)     │ │
│  └─────────────────┘  └──────────────────────┘ │
└───────────────────────┬─────────────────────────┘
                        │ XPC (MachService)
┌───────────────────────┴─────────────────────────┐
│  ChargeKitHelper (root LaunchDaemon)            │
│  • Privileged SMC writes (whitelist)            │
│  • Discharge session management                 │
│  • Low Power Mode (pmset)                       │
│  • Exit safety: restore charging + adapter      │
└─────────────────────────────────────────────────┘
```

- **ChargeKitCore** — pure decision logic (heat > limit-toggle > sailing), fully unit-tested
- **SMCKit** — AppleSMC IOKit client, verified ABI (selector 2 + selector-5 read)
- **ChargeKitHelper** — root daemon owning privileged writes; crash-safe (all exit paths restore state)
- **ChargeKitApp** — SwiftUI menu-bar popover + settings window; no privileged code

## Security notes

- SMC writes are whitelisted to charge-control keys (`CHTE`, `CHIE`, `BCLM`, etc.)
- The helper daemon restores charging + adapter on every exit path (SIGTERM, crash, uninstall)
- The XPC connection currently validates PID only (no code-signing verification) — suitable for single-user machines; audit-token verification is planned for multi-user environments
- Update signing (Sparkle EdDSA) private key is kept in three places: the
  `SPARKLE_PRIVATE_KEY` GitHub Secret (release builds), the local login
  keychain, and `secrets/sparkle-private-key.b64` (git-ignored). If the
  Secret is ever lost, restore it with:
  `gh secret set SPARKLE_PRIVATE_KEY < secrets/sparkle-private-key.b64`

## Debug CLI

`smcctl` provides direct access for debugging:

```bash
.build/release/smcctl smc2-read BUIC        # Read battery percent
.build/release/smcctl smc2-read PDTR        # Read input power
.build/release/smcctl helper-test           # XPC round-trip
.build/release/smcctl helper-adapter on     # Enable adapter
.build/release/smcctl helper-discharge on 75 hw  # Start discharge
```

## Known limitations

- The macOS native charge limit (System Settings → Battery) caps what any third-party app can do; if it's below 100%, ChargeKit detects and reports the conflict
- BUIC (BMS percent) can "stick" at 100% near full charge while the macOS gauge reads lower — this is normal hardware behavior
- The MagSafe LED is reset by the system on adapter re-plug; ChargeKit re-asserts within 2 seconds

## License

[MIT](LICENSE) — free to use, modify, and distribute.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and guidelines.

## Credits

SMC communication approach informed by [Battery-Toolkit](https://github.com/mhaeuser/Battery-Toolkit) (BSD-3-Clause). Feature set inspired by community feedback.
