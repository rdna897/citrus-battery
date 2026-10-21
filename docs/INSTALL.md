# Install Citrus Battery

Open the [latest GitHub release](https://github.com/rdna897/citrus-battery/releases/latest)
and use the **Download the application** links. You only need one application ZIP:

- **Apple Silicon (M1 or later):** the ZIP containing `arm64`.
- **Intel:** the ZIP containing `x86_64`.

To check, open **Apple menu → About This Mac** and look for an Apple chip or an
Intel processor. The minimum macOS version is part of the filename; check it
before downloading.

Choose the ZIP without `-sources` in its name. The `-sources.zip` files and
GitHub's **Source code** archives contain source code, not the application.
The `.sha256` files are optional checksums. Homebrew is not needed to run the app.

1. Extract the ZIP and drag **Citrus Battery.app** into **Applications**.
2. Open the app. macOS may block it because Apple cannot verify the developer.
3. If you trust this release, open **System Settings → Privacy & Security**,
   scroll to Security, and choose **Open Anyway**. Confirm **Open** and
   authenticate if prompted. Do this soon after the blocked launch attempt.

These releases use an **ad hoc signature**, which detects changes to the bundle
but does not verify who published it. They are **not notarized by Apple**.
No paid Apple Developer account is used. You may need to approve a later update
again. Managed Macs may prevent this exception.

Apple documents the first-launch process in
[Open apps safely on your Mac](https://support.apple.com/en-gb/102445).

Each ZIP has a `.sha256` file. To check a download in Terminal, put both files in
the same folder and run `shasum -a 256 -c <filename>.zip.sha256`, replacing
`<filename>` with the downloaded archive name. This checks the file against the
published checksum; it does not authenticate the publisher independently.

From **version 1.1**, Citrus Battery can check GitHub daily for new versions. On
its second launch, it asks whether to check automatically. If you also allow
automatic installation, updates download in the background and install when you quit;
otherwise Citrus Battery shows each update and lets you choose.
Choose **Citrus Battery → Check for Updates…** (also available in the menu bar
panel) to check immediately and install with a relaunch. Change automatic checks
and downloads in **Settings → Updates**. Updates use the build for your Mac's
architecture and macOS version, and verify cryptographic signatures before
installation. Updates require an internet connection to GitHub.

If you have **version 1.0.1 or earlier**, install 1.1 manually once: quit Citrus
Battery and replace the app in Applications with the new copy. You can also use
this method if an automatic update fails. Battery history and preferences are
kept separately from the app.

For an iPhone or iPad, connect it by USB and accept **Trust This Computer** on the
device first. Wi-Fi access depends on the device being paired with the Mac and
available on the network. macOS may ask for Local Network access. Notifications
and Open at Login also need the relevant macOS permissions.
