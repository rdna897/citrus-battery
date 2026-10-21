# Install Citrus Battery

Releases are distributed on GitHub. Choose the ZIP for your Mac: `arm64` for
Apple Silicon (M1 or later), or `x86_64` for Intel. The minimum macOS version is
part of the filename; check it before downloading. Homebrew is not needed to run
the app.

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

To update, quit Citrus Battery and replace the app in Applications with the new
copy. Updates are installed manually. Battery history and preferences are kept
separately from the app.

For an iPhone or iPad, connect it by USB and accept **Trust This Computer** on the
device first. Wi-Fi access depends on the device being paired with the Mac and
available on the network. macOS may ask for Local Network access. Notifications
and Open at Login also need the relevant macOS permissions.
