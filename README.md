<img src="assets/icon.svg" width="64" height="64" alt="">

# Citrus Battery

An open-source battery monitor for macOS, aiming to cover everything coconutBattery
does, including the features it sells as "Plus". Nothing is paywalled.

> **Status:** early. The Mac battery view works; iPhone/iPad support, history, the
> menu bar app and the rest are planned. See [docs/FEATURE_SPEC.md](docs/FEATURE_SPEC.md)
> for the full feature list and build order.

## What works today

- Live Mac battery readings: charge, health (full-charge ÷ design capacity), cycle
  count, temperature, voltage, amperage, time remaining, adapter details, cell
  manufacturer, manufacture date (or week, where the battery records no year), and
  decoded permanent-failure flags.
- Power readings from the SMC: system usage, 1-minute maximum, adapter input,
  charging/discharging watts, CPU temperature, and a live power chart.
- Settings: 8 temperature units, mAh or Wh, raw or macOS-style percentages,
  delayed (smoothed) or fast (1 s) refresh.
- Works on both Apple Silicon and Intel register layouts.

## Building

Requires macOS 13 or later and Swift 6 (Xcode or just the Command Line Tools).

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
