# ChargeKit

A native macOS charge limiter that gives you full control over your MacBook's charging behavior — using only public APIs.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/Tests-269%20passed-brightgreen)

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
| Battery info | Design capacity, health %, cycle count, temperature, live power flow, smoothed runtime estimate |
| Hardware % | Toggle between macOS gauge and BMS-direct battery percentage |
| Clamshell discharge | Discharge works with lid closed (automatic sleep prevention) |
| Right-click menu | Menu-bar context menu: settings, about, and quit |

## How it works

ChargeKit communicates with the AppleSMC kernel driver via IOKit to read battery telemetry and control charging. A privileged helper daemon (installed via LaunchDaemon) performs the actual SMC writes.

| Mac | Charge control |
|-----|----------------|
| Apple silicon with macOS Tahoe 26.4 or later | Set the 80–100% limit in System Settings → Battery → Charging. ChargeKit monitors power and charging status. |
| Earlier systems with a supported independent charging switch | ChargeKit manages its own limit, sailing, and heat protection. |
| Other configurations | Battery monitoring only. |

System-managed mode suspends ChargeKit charging schedules and retains
Low Power Mode schedules. It can restore a stale adapter cut even while the
system charge limit is pending. On Mac17,2 with macOS 26.7.3, the adapter
recovered while ChargeKit stayed open and macOS reported 80% and not charging.

**Key SMC registers used:**
- `CHTE` — charge switch (stop/start charging, adapter keeps powering the Mac)
- `CHIE` — adapter switch (physically disconnect wall power, for discharge)
- `VD0R` — DC-in voltage; the only "cable attached" signal that survives an adapter cut (IOPowerSources reports battery while `CHIE` cuts input)
- `BUIC` — battery percent (BMS-direct)
- `PDTR` — input power (W)
- `TB0T` — battery temperature (°C)
- `B0AV`/`B0AC` — battery voltage/current
- `ACLC` — MagSafe LED color

All reads are unprivileged; writes go through the root daemon with a whitelist of charge-control keys only.

## Requirements

- macOS 13 Ventura or later
- Apple Silicon MacBook
- Xcode Command Line Tools (Swift 6+)

## Download & Install

1. Download the latest `ChargeKit-vX.Y.Z.dmg` from
   [Releases](https://github.com/HanYunChenLuo/ChargeKit/releases/latest)
2. Open the DMG and drag **ChargeKit** into `/Applications`
3. First launch — macOS Gatekeeper will warn that the app is from an
   unidentified developer (the app is ad-hoc signed). Allow it once:
   - **macOS 15+**: open the blocked app once from
     *System Settings → Privacy & Security → Open Anyway*
   - **macOS 13/14**: right-click the app → **Open** → **Open**
4. Battery monitoring and macOS-managed charging work without the
   privileged helper. macOS asks for administrator approval when ChargeKit
   first needs to perform a privileged operation.

After the first launch, updates are delivered automatically through
Sparkle — no further Gatekeeper prompts are needed.

## Build & Install

```bash
git clone https://github.com/YOUR_USERNAME/ChargeKit.git
cd ChargeKit

# Build everything
swift build -c release

# Run the test suite (269 assertions)
swift run policy-tests

# Build and launch the app
./scripts/build-app.sh
open build/ChargeKit.app
```

ChargeKit installs and connects to the bundled helper on demand for
software charging control, Low Power Mode writes, MagSafe LED writes,
or adapter recovery when a previous cut is detected. The native-limit
version split is Apple silicon on macOS 26.4 or later, as implemented
starting in ChargeKit v0.6.1. A manual install is also available:

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
- **ChargeKitHelper** — root daemon owning privileged writes and adapter recovery
- **ChargeKitApp** — SwiftUI menu-bar popover + settings window; no privileged code

## Security notes

- XPC exposes typed charging and discharge controls. Raw writes are limited to
  the MagSafe LED key (`ACLC`).
- Before a discharge cuts adapter input, the helper records the recovery
  obligation in `/var/db`. `launchd` can relaunch it while the record exists,
  and the helper keeps retrying until it reads back the enabled adapter state.
- Non-root XPC clients must match the app signing hash recorded by the
  administrator-approved installer. The first privileged operation after an
  app rebuild or update can require approval to refresh that hash.
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
sudo .build/release/smcctl helper-test           # XPC round-trip
sudo .build/release/smcctl helper-adapter on     # Enable adapter
sudo .build/release/smcctl helper-discharge on 75 hw  # Start discharge
.build/release/smcctl enumerate CH          # List SMC keys (sub-8)
.build/release/smcctl snapshot              # Dump all CH* key values
sudo .build/release/smcctl probe-writable CHIE bfD0  # Write-permission probe
```

## Known limitations

- In system-managed mode, macOS sets the charging target and may occasionally charge to 100% to recalibrate its state-of-charge estimate.
- BUIC (BMS percent) can "stick" at 100% near full charge while the macOS gauge reads lower — this is normal hardware behavior
- The MagSafe LED is reset by the system on adapter re-plug; ChargeKit re-asserts within 2 seconds

## License

[MIT](LICENSE) — free to use, modify, and distribute.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and guidelines.

## Credits

SMC communication approach informed by [Battery-Toolkit](https://github.com/mhaeuser/Battery-Toolkit) (BSD-3-Clause). Feature set inspired by community feedback.
