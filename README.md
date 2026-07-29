# Fathom

Local-only **macOS menu bar battery monitor** — what’s drawing power, why battery dropped, and time remaining.

Product page: [chopstickshq.com/fathom](https://chopstickshq.com/fathom/)

**Current:** `v0.2.20-Beta` · ultra-light idle CPU (typically well under 1%)

## Features

- Menu bar battery icon (optional replace system Battery item)
- Package power via IOReport (Apple Silicon) + battery watts from SmartBattery
- Multi-source battery merge (IOPS + SmartBattery; rare shell cross-check)
- Top processes by local energy-impact estimate
- “Why did battery drop?” from a local drain log (no telemetry)
- Full window dashboard (double-click menu bar icon)
- Optional drain alerts (local notifications)

## Requirements

- macOS 13+
- Apple Silicon preferred (Intel works with reduced sensors)
- Xcode Command Line Tools (for compile install)

## Install

### One-liner (recommended)

```bash
curl -fsSL https://chopstickshq.com/fathom/install.sh -o /tmp/fathom-install.sh && bash /tmp/fathom-install.sh
```

### From this repo

```bash
bash install-fathom.sh
```

App installs to `~/Applications/Fathom.app`.

### Prebuilt ZIP

See [`releases/`](releases/) for `Fathom-v0.2.20-Beta.zip`.

Older builds: [`releases/archive/`](releases/archive/).

## Build from source

```bash
swiftc Sources/FathomApp.swift -o Fathom \
  -framework SwiftUI -framework Cocoa -framework IOKit -lIOReport \
  -parse-as-library -O
```

Or:

```bash
./scripts/build-release.sh
```

## Repo layout

```
Sources/          Swift source + app icons
scripts/          Release & icon helpers
releases/         Current Beta / Experimental packages
releases/archive/ Older versioned .sh / .zip
install-fathom.sh Compile-from-source installer (integrity-hashed)
version.json      Channel pointers for the website / updater
changelog.json    Release notes
```

## Privacy

- **Local only** — no accounts, no product telemetry
- Optional update check reads `version.json` from chopstickshq.com
- Drain log: `~/Library/Application Support/Fathom/drain.jsonl`

## License

MIT — see [LICENSE](LICENSE).
