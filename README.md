<img src="assets/icon.svg" width="64" height="64" alt="">

# Citrus Battery

An open-source battery monitor for macOS, aiming to cover everything coconutBattery
does, including the features it sells as "Plus". Nothing is paywalled.

> **Status:** early. The Mac and iPhone/iPad battery views, history, menu bar,
> notifications and Advanced Viewer work; smaller items are still planned. See [docs/FEATURE_SPEC.md](docs/FEATURE_SPEC.md)
> for the full feature list and build order.

## What works today

- Live Mac battery readings: charge, health (full-charge ÷ design capacity), cycle
  count, temperature, voltage, amperage, time remaining, adapter details, cell
  manufacturer, manufacture date (or week, where the battery records no year), and
  decoded permanent-failure flags.
- Power readings from the SMC: system usage, 1-minute maximum, adapter input,
  charging/discharging watts, CPU temperature, and a live power chart.
- Charge limits: macOS Charge Limit and Optimized Battery Charging, plus running
  third-party limiters, with advice where a limit can skew reported capacity.
- History: SmartSave records the battery about once an hour when it changes (per-device
  switch), History window with a health chart, sortable table, copy, delete, JSON
  backup export/import, and import of coconutBattery backups (`.ccba`, needs
  coconutBattery installed because the file is encrypted with a key built into it). Stored in `~/Library/Application Support/Citrus Battery/`.
- Menu bar: customisable status text using coconutBattery's placeholders (`%CHARGE%`,
  `%CC%`, `%CUSTEMP%`, `%HEALTH%`, `%TIMEREM%`, `%STATUS%`, `%SYSWATT%`, `%BATWATT%`,
  `%CHARGER%`), battery icon, and a panel with charge, health and power. Optional
  open at login and menu-bar-only mode (no Dock icon).
- Notifications: low charge, low time remaining and fully charged, each once per
  discharge and at most every 15 minutes (needs the app bundle).
- Advanced Viewer (per device, "Advanced…" in the toolbar): every value the battery and
  device report as a searchable tree, NVMe SSD health (life used, data read/written,
  power-on hours, errors) plus since-boot statistics, displays and USB devices, with
  copy as tab-separated text. `CitrusBattery --advanced` prints the same.
- Full Mac model names ("MacBook Air (13-inch, M4, 2025)") and, for Intel Macs, the
  manufacture date from the serial number.
- A low-health notice below 80% with a replacement search (iFixit), Help → Find
  Replacement Battery and Copy Diagnostic Report, View → History (⌘Y) and Advanced
  Viewer (⌥⌘I), and `citrusbattery://mac|history|device/<udid>|advanced[/<udid>]` links.
- Settings: 8 temperature units, mAh or Wh, raw or macOS-style percentages,
  delayed (smoothed) or fast (1 s) refresh.
- iPhone and iPad: devices connected by USB, or over Wi-Fi when "Show this iPhone when
  on Wi-Fi" is on in Finder, appear in the sidebar and menu bar panel with charge,
  health, cycles, temperature, lifetime data and product icons. SmartSave records them
  in History, and an optional notification fires when a device charges to a chosen
  level. `CitrusBattery --ios` prints the same data.
- Works on both Apple Silicon and Intel register layouts.

## Building

Requires macOS 13 or later, Swift 6 (Xcode or just the Command Line Tools), and
libimobiledevice from Homebrew for iPhone/iPad support:

```bash
brew install libimobiledevice
```

`scripts/build-app.sh` copies libimobiledevice and its dependencies into the app
bundle, so the built app runs on Macs without Homebrew.

```bash
swift build                      # debug build
./scripts/build-app.sh           # release build → dist/Citrus Battery.app
```

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
| `Sources/CSMC` | C shim for the AppleSMC user client |
| `Sources/CitrusKit` | Data layer: SMC, battery registry, power source, units, failure flags |
| `Sources/CitrusBattery` | SwiftUI app |
| `Tests/CitrusKitTests` | Unit tests, including fixtures from real Apple Silicon and Intel layouts |
| `docs/FEATURE_SPEC.md` | Feature inventory and implementation notes |

## License

Citrus Battery is free software, licensed under the
[GNU General Public License v3.0](LICENSE).

Created in [T3 Code](https://t3.codes).
