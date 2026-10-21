Citrus Battery 1.0.1 is a free, open source battery monitor for macOS, iPhone and iPad.
Please report problems through GitHub Issues.

## Download the application

**Requires macOS 15 or later. Download just one ZIP for your Mac:**

| Your Mac | Application download |
| --- | --- |
| **Apple Silicon — M1 or later** | **[Download Citrus Battery for Apple Silicon](https://github.com/rdna897/citrus-battery/releases/download/v1.0.1/CitrusBattery-1.0.1-arm64-macOS15.0.zip)** (`arm64`) |
| **Intel** | **[Download Citrus Battery for Intel](https://github.com/rdna897/citrus-battery/releases/download/v1.0.1/CitrusBattery-1.0.1-x86_64-macOS15.0.zip)** (`x86_64`) |

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

Updates are manual: quit Citrus Battery and replace the app in Applications.
Your battery history and preferences are stored separately from the app.

## Fixed in 1.0.1

- Fixed a crash during launch while reading notification settings.
- Fixed the same threading issue when requesting notification permission.

## Included features

Mac battery health, charge cycles, temperature, power readings, charger details,
charge limit detection, iPhone/iPad monitoring over USB and Wi-Fi, automatic
history recording, lifetime data, an advanced hardware viewer, a customizable
menu bar, notifications and Open at Login.

Data availability depends on the Mac, battery and iOS device. Online comparisons,
printable reports and automatic app updates are not included in this release.

## Optional: source code and checksums

- `-sources.zip` archives are for developers. They include the matching application
  source, bundled libraries' upstream source archives, and Homebrew build metadata.
- GitHub's **Source code** archives contain the repository source at this release.
- `.sha256` files are checksums for verifying a downloaded ZIP.

Homebrew is not required to run the app.
