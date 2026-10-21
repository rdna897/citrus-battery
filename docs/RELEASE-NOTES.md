Citrus Battery is a free, open source battery monitor for macOS, iPhone and iPad.
This is an early development release; please report problems through GitHub Issues.

## Downloads

- Choose the app ZIP containing `arm64` for Apple Silicon, or `x86_64` for Intel.
- Each filename includes the minimum macOS version required by that build.
- ZIPs containing `sources` include the matching application source, bundled
  libraries' upstream source archives, and Homebrew build metadata.
- Each ZIP has a SHA-256 checksum file. Homebrew is not required to run the app.

## Installation and first launch

Extract the app ZIP and drag **Citrus Battery.app** into **Applications**.
The app uses ad hoc signing and **is not notarized by Apple**. macOS may block its
first launch. If you trust this release, try opening it, then go to
**System Settings → Privacy & Security → Open Anyway** and confirm **Open**.
Later updates may need approval again. Managed Macs may prevent this exception.
See [Apple's first-launch guidance](https://support.apple.com/en-gb/102445).

Updates are manual: quit Citrus Battery and replace the app in Applications.
Your battery history and preferences are stored separately from the app.

## Included features

Mac battery health, charge cycles, temperature, power readings, charger details,
charge limit detection, iPhone/iPad monitoring over USB and Wi-Fi, automatic
history recording, lifetime data, an advanced hardware viewer, a customizable
menu bar, notifications and Open at Login.

Data availability depends on the Mac, battery and iOS device. Online comparisons,
printable reports and automatic app updates are not included in this release.
