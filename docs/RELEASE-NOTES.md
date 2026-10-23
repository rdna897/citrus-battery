Citrus Battery 1.2.1 is a free, open source battery monitor for macOS, iPhone and iPad.
Please report problems through GitHub Issues.

## Download the application

**Requires macOS 13 or later. Download just one ZIP for your Mac:**

| Your Mac | Application download |
| --- | --- |
| **Apple Silicon — M1 or later** | **[Download Citrus Battery for Apple Silicon](https://github.com/rdna897/citrus-battery/releases/download/v1.2.1/CitrusBattery-1.2.1-arm64-macOS13.0.zip)** (`arm64`) |
| **Intel** | **[Download Citrus Battery for Intel](https://github.com/rdna897/citrus-battery/releases/download/v1.2.1/CitrusBattery-1.2.1-x86_64-macOS13.0.zip)** (`x86_64`) |

To check which Mac you have, open **Apple menu → About This Mac**. An Apple chip
means Apple Silicon; an Intel processor means Intel.

The links above contain **Citrus Battery.app**. Files ending in `-sources.zip`,
GitHub's **Source code (zip)** and **Source code (tar.gz)**, and `.sha256` files
are **not application downloads**. You do not need them to install the app.

## Installation and first launch

Extract the app ZIP and drag **Citrus Battery.app** into **Applications**.
The app uses ad hoc signing and **is not notarized by Apple**. macOS may block its
first launch. If you trust this release, try opening it, then go to
**System Settings → Privacy & Security → Open Anyway** and confirm **Open**.
Later updates may need approval again. Managed Macs may prevent this exception.
See [Apple's first-launch guidance](https://support.apple.com/en-gb/102445).

**Using 1.1 or later?** Citrus Battery offers this update itself. **Upgrading from 1.0.1 or
earlier?** Quit Citrus Battery and replace the app in Applications with this version.
Your battery history and preferences are kept.

## New in 1.2.1

- **macOS's own battery icon.** The menu bar shows the same battery icon as macOS,
  drawn by macOS itself: filled to the exact charge, with a bolt while charging and a
  plug when charging is paused. Like macOS's, it turns yellow in Low Power Mode and red
  when the battery is nearly empty. A new setting writes the percentage inside the
  icon, as macOS can, alongside or instead of the menu bar text.
- **A menu that looks like macOS's.** The menu bar panel now follows Control Center's
  menus: charge and health bars, a details list, your iPhones and iPads, and on
  macOS 26 or later the same rounded glass. It shows when Low Power Mode is on, says
  **Charging On Hold** when a charge limit is holding the charge, and has a
  **Battery Settings…** shortcut.
- **Clearer power history.** The 1 hour to 30 day views now show battery level and
  power use as bars, like the charts in macOS's Battery settings, with the Mac's sleeps
  on a strip underneath. Brief wakes during sleep show as small power bars and in the
  readout when you hover over a sleep.
- **Start quietly at login.** With **Open at login** on, Citrus Battery can start in
  the menu bar without opening its window, or minimised when the menu bar item is off.
- **Shorter update message.** Checking for updates when you're up to date now just
  says so.

## New in 1.2

- **Health forecast.** History draws a trend line through the last year of readings
  and estimates how fast the battery is losing capacity and roughly when it will reach
  80%. The device pages show the same estimate as **Health trend**.
- **Power history.** The power chart now covers the last 2 minutes, hour, 24 hours,
  7 days or 30 days, with the battery's charge level underneath and the times the Mac
  was asleep shaded, and the brief wakes macOS makes while the Mac sleeps. On
  macOS 14 or later, hover over the chart for exact readings. History starts when you
  install this version, and until there's enough, the chart starts where it begins.
- **Clearer battery readings.** When the battery is resting on the charger, the Power
  card says "Not charging (running on adapter)" instead of "Charging with 0.0 W".
- **Charger check.** A new Charger card shows the charger's name and maker, the power
  it agreed with the Mac or device, the USB-C voltages it offers and how much it is
  supplying now. It says when the charger limits charging speed, is a basic 5 V supply,
  or can't keep up and the battery drains while plugged in.
- **Cell voltages.** The voltage of each cell in the pack, with a warning when they
  drift apart.
- **Sleep drain.** How much charge the Mac lost during each sleep of 30 minutes or
  more on battery, with a warning when it is unusually high.

## Included features

Mac battery health and its forecast, charge cycles, temperature, cell voltages,
power readings, a charger check, sleep drain, charge limit detection, iPhone/iPad
monitoring over USB and Wi-Fi, automatic history recording, lifetime data, an
advanced hardware viewer, a customizable menu bar, notifications and Open at Login.

Data availability depends on the Mac, battery and iOS device. Online comparisons
and printable reports are not included in this release.

## Optional: source code and checksums

- `-sources.zip` archives are for developers. They include the matching application
  source, the bundled libraries' upstream source archives and their licenses.
- GitHub's **Source code** archives contain the repository source at this release.
- `.sha256` files are checksums for verifying a downloaded ZIP.
- `appcast-*.xml` files are signed update feeds used by the application. You do
  not need to download them yourself.

Homebrew is not required to run the app.
