Citrus Battery 1.3 is a free, open source battery monitor for macOS, iPhone and iPad.
Please report problems through GitHub Issues.

## Download the application

**Requires macOS 13 or later. Download just one ZIP for your Mac:**

| Your Mac | Application download |
| --- | --- |
| **Apple Silicon — M1 or later** | **[Download Citrus Battery for Apple Silicon](https://github.com/rdna897/citrus-battery/releases/download/v1.3/CitrusBattery-1.3-arm64-macOS13.0.zip)** (`arm64`) |
| **Intel** | **[Download Citrus Battery for Intel](https://github.com/rdna897/citrus-battery/releases/download/v1.3/CitrusBattery-1.3-x86_64-macOS13.0.zip)** (`x86_64`) |

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

## New in 1.3

- **Sleep page.** Every sleep on battery is kept, with the average drain, loss per
  sleep, total lost and brief wakes for the last 7, 30 or 90 days, all time or dates
  you choose. A chart shows each sleep's drain per hour and a table lists when the Mac
  slept and woke, for how long and what it lost.
- **Why the Mac woke.** For each sleep, the reasons macOS woke the Mac briefly with
  the screen off: scheduled tasks, network upkeep, push notifications, or Wi-Fi and
  Bluetooth, and which scheduled tasks woke it most. Click a sleep in the chart or
  table to see just that sleep. **Show Details…** lists every brief wake with how long
  the Mac stayed awake, what kept it awake and which apps iCloud or background
  downloads worked for. Reasons come from macOS's power log, which keeps about a week,
  so they start with sleeps from the week before you install this version.
- **Energy by app.** A new card on the This Mac page ranks apps by the energy they
  used over the last hour, 24 hours, 7 days or 30 days, in all or on battery only,
  with helpers counted towards their app. On Intel Macs it ranks by processor time.
- **Apps preventing sleep.** The menu and the This Mac page show apps keeping the Mac
  awake or its display on, such as a call, audio playing or `caffeinate`, and for how
  long. The menu also lists apps using significant energy, as macOS's battery menu does.
- **Settings in the main window.** Settings is now a page in the sidebar, laid out like
  System Settings. Pick the menu bar items you want instead of typing a format; text
  you set up in an earlier version is kept. Battery icon has its own switch, and new
  installs show percentages the way macOS does.
- **Software Update-style checks.** Settings shows the installed version with a
  **Check Now** button and the result in place, with **Update Now…** when one is ready.
- **The current macOS look.** The app and its menu use the system's own glass and
  styling on macOS 26 or later.
- **Power history.** Hover over a chart to see the exact time. The 7 and 30 day views
  appear once there's that much history. The Mac's details also show CPU usage and Low
  Power Mode, and say "Calculating…" while macOS works out the time remaining.
- **Backups include sleep history.** Backups now carry sleeps and their wake reasons,
  and importing one skips what's already there. Sleeps from another Mac's backup are
  kept apart from this Mac's. A damaged backup is refused whole instead of being
  partly imported, and imports run without freezing the window.
- **Fixes.** The iPhone/iPad charge notification now arrives when a device finishes
  charging at 100%. Save Now no longer saves an unchanged reading twice. Charts, the
  Advanced Viewer and History stay responsive with a month of readings or a slow
  external drive, and saved work finishes before the app quits.

Your history is upgraded the first time 1.3 opens it. Earlier versions can still open
it afterwards, but don't record sleep reasons or app energy.

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
power readings, a charger check, sleep drain and history with wake reasons, energy
use by app, apps preventing sleep, charge limit detection, iPhone/iPad
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
