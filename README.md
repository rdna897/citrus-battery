<img src="assets/icon.svg" width="128" height="128" alt="Citrus Battery icon">

# Citrus Battery

Citrus Battery shows how your Mac's battery is really doing, and your iPhone's and
iPad's too. You get live charge, health, charge cycles, temperature and power draw.
It keeps a history of how capacity changes over time, and records everything the
battery's gauge has logged over its life. It's free, open source, and every feature
is included.

> **Status:** early development. GitHub releases are prereleases; data availability
> varies by hardware and OS version.

## Download and install

Get the Apple Silicon (`arm64`) or Intel (`x86_64`) ZIP from
[GitHub Releases](https://github.com/rdna897/citrus-battery/releases).
The filename states the minimum macOS version for that build. Extract it and
drag **Citrus Battery.app** into **Applications**. Homebrew is not needed to run it.

Releases use **ad hoc signing** and are **not notarized by Apple**. If macOS blocks
the first launch, and you trust the release, try opening the app and then use
**System Settings → Privacy & Security → Open Anyway**. See the full
[installation instructions](docs/INSTALL.md) and
[Apple's first-launch guidance](https://support.apple.com/en-gb/102445).
Updates are installed manually.

## Features

**Your Mac's battery**
- Charge, health (full-charge capacity ÷ design capacity), charge cycles, temperature,
  voltage, current, time remaining and charger details.
- Battery manufacturer and manufacture date. The date comes from what the battery
  records or from its serial number, or is estimated from its operating hours.
- Power use from the SMC: system usage, its 1-minute peak, adapter input, battery
  charge or discharge rate, CPU temperature, and a live power chart.
- Charge limits: shows macOS's Charge Limit and Optimized Battery Charging, and spots
  third-party charge limiters (AlDente, Battery Toolkit, batt). Where a limit can make
  reported capacity read low, it says so.
- Permanent battery failure flags, decoded.
- A notice when health falls below 80%, with a link to search for a replacement.

**iPhone and iPad**
- Devices connected by USB or on the same Wi-Fi network appear in the sidebar and menu
  bar, with charge, health, cycles, temperature, charger and lifetime data.
- Shows when iOS has paused charging because of Charge Limit or Optimized Battery
  Charging.

**History**
- Auto-Record saves each battery about once an hour when something changes.
- A health chart, a sortable table, JSON backup and restore, and import of
  coconutBattery backups (`.ccba`, which needs coconutBattery installed).

**Battery Lifetime Data**
- Total operating time, age, temperature and pack-voltage extremes, peak charge and
  discharge current (also as a C-rate), the number of temperature samples, the last
  gauge calibration and any battery failures. Available for the Mac and each device.

**Advanced Viewer**
- Every value the battery and device report, as a searchable tree. Also NVMe SSD
  health (life used, data read and written, power-on hours, errors), displays and
  USB devices. Everything can be copied as tab-separated text.

**Menu bar and notifications**
- Status text you can customise with placeholders (`%CHARGE%`, `%CC%`, `%CUSTEMP%`,
  `%HEALTH%`, `%TIMEREM%`, `%STATUS%`, `%SYSWATT%`, `%BATWATT%`, `%CHARGER%`), plus a
  panel showing your Mac and devices. Can open at login, with an optional
  menu-bar-only mode.
- Notifications for low charge, low time remaining, fully charged, and an iPhone/iPad
  reaching a chosen level.

**Settings**
- 8 temperature units, mAh or Wh, raw or macOS-style percentages, and a smoothed or
  fast (1-second) refresh.
- `citrusbattery://` links (`mac`, `history`, `device/<udid>`, `advanced[/<udid>]`,
  `lifetime[/<udid>]`) and command-line output (`--dump`, `--ios`, `--advanced`).

Works on Apple Silicon and Intel Macs.

## Comparison

How Citrus Battery compares with coconutBattery 4.4, free and Plus:

| Feature | Citrus Battery | coconutBattery | coconutBattery Plus |
|---|:-:|:-:|:-:|
| Price | Free | Free | Paid |
| Source code | Open (GPL v3) | Closed | Closed |
| Mac battery: charge, health, cycles, temperature | ✓ | ✓ | ✓ |
| Battery manufacturer and manufacture date | ✓ | ✓ | ✓ |
| Live power use | ✓ | ✓ | ✓ |
| Charge limit detection and advice | ✓ | — | — |
| iPhone/iPad over USB | ✓ | ✓ | ✓ |
| iPhone/iPad over Wi-Fi | ✓ | — | ✓ |
| History with automatic recording, backups | ✓ | ✓ | ✓ |
| Menu bar status | ✓ | ✓ | ✓ |
| Custom menu bar text | ✓ | — | ✓ |
| Notifications | ✓ | — | ✓ |
| Battery Lifetime Data | ✓ | — | ✓ |
| Advanced Viewer (SSD health, displays, USB) | ✓ | — | ✓ |
| Wh units and fast refresh | ✓ | — | ✓ |
| All 8 temperature units | ✓ | 2 | ✓ |
| Compact "Classic" layout | — | ✓ | ✓ |
| Printable information sheet | — | ✓ | ✓ (custom templates) |
| Online comparison with other devices | — | ✓ | ✓ |
| Automatic updates | Planned | ✓ | ✓ |

## Building

The source targets macOS 13 or later. Building requires Swift 6 (Xcode or the
Command Line Tools), Python 3,
libimobiledevice from Homebrew for iPhone/iPad support, and librsvg to render the
app icon:

```bash
brew install libimobiledevice librsvg
```

`scripts/build-app.sh` copies libimobiledevice and its dependencies into the app
bundle, so the built app runs on Macs without Homebrew. The final app's minimum
macOS version is determined by the executable and bundled libraries; newer
Homebrew builds can raise it above macOS 13.

```bash
swift build                      # debug build
./scripts/build-app.sh           # release build → dist/Citrus Battery.app
VERSION=0.1.0 ./scripts/package-release.sh  # ZIPs, matching sources and checksums
```

Packaging needs a clean, committed checkout. See [releasing](docs/RELEASING.md)
for the GitHub workflow and publishing instructions.

Command-line helpers:

```bash
.build/debug/CitrusBattery --dump              # print current readings
.build/debug/CitrusBattery --snapshot out.png  # render the main view to an image
```

## Testing

```bash
swift test
```

With only the Command Line Tools installed, Swift Testing's macro plugin isn't on the
default search path, so pass it explicitly:

```bash
swift test -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

## Layout

| Path | Contents |
|---|---|
| `Sources/CSMC` | C shims for the AppleSMC user client and NVMe SMART |
| `Sources/CPowerUI` | Read-only charge limit status from macOS |
| `Sources/CIDevice` | iPhone/iPad access through libimobiledevice |
| `Sources/CitrusKit` | Data layer: battery, power, devices, history, units |
| `Sources/CitrusBattery` | SwiftUI app |
| `Tests/CitrusKitTests` | Unit tests, including fixtures from real Apple Silicon and Intel layouts |

## License

Citrus Battery is free software, licensed under the
[GNU General Public License v3.0](LICENSE).
