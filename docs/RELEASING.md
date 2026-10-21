# GitHub releases

The public repository is [rdna897/citrus-battery](https://github.com/rdna897/citrus-battery).
Distribution uses GitHub Releases with ad hoc signing (`codesign --sign -`).
It needs no Apple Developer account, signing certificate, provisioning profile,
or notarization credentials. Users approve the first launch as described in
[INSTALL.md](INSTALL.md).

## Versions

The root `VERSION` file is the single source of the app's public version.
The app's About window, archive names and GitHub release use that version.
Release tags must be exactly `v` followed by the file's value; the workflow
rejects a mismatched tag.

- `1.0`: the first release in the numbered series.
- `1.0.1`, `1.0.2`: fixes to the 1.0 release.
- `1.1`, `1.2`: new features within the same major version.
- `2.0`: major compatibility changes.

`CFBundleVersion` also uses `VERSION`, so Sparkle compares public versions in
order across local and CI builds. The separate `CitrusBuildNumber` identifies a
particular build: GitHub uses the workflow run number, and local builds use the
commit count unless `BUILD` is specified.
The earlier `v0.1.0` prerelease remains available as a historical preview.

## Build and validate

Install the dependencies from the README and commit the release changes. Then:

```bash
swift test
./scripts/package-release.sh
```

Packaging requires a clean checkout, builds the app for the host architecture,
verifies the app signature before and after extraction, runs the extracted app's
command-line diagnostics, checks that bundled libraries include that
architecture, and rejects remaining external Homebrew links. It first runs
`scripts/build-dependencies.sh`, which builds libimobiledevice and its libraries
from pinned source releases for macOS 13, and stops if the finished app requires
a newer macOS than 13.0.

Packaging also runs the extracted app through normal GUI startup. It must finish
reading notification settings and open a visible application window, then exit
cleanly. This check exercises code that the command-line diagnostics do not run.
It launches through LaunchServices, as Finder does. On the hosted Intel VM,
which can fail in Metal rendering, CI runs the notification startup check
without rendering; Apple Silicon runs the full GUI check. Verify the downloaded
Apple Silicon candidate on a physical Mac before publishing a startup fix.
To run it separately on a built app:

```bash
python3 scripts/test-app-launch.py "dist/Citrus Battery.app"
```

The archives in `dist/` contain the app and installation instructions, matching
source code and dependency sources, licenses, build metadata, and SHA-256 files.
Upstream source downloads are checked against the SHA-256 hashes pinned in
`scripts/build-dependencies.sh`.
Packaging stops if the source metadata or a source download cannot be verified.
The pinned Sparkle source revision and its license are included as well.

## Updater signing

Sparkle 2 verifies Ed25519 signatures on both update feeds and application ZIPs.
This signing key is separate from Apple code signing and needs no paid account.
`assets/update-public-key.txt` is embedded in every application. The matching
private key is in the maintainer's login Keychain under account `citrus-battery`
and in the repository's **SPARKLE_PRIVATE_KEY** Actions secret. Never commit it
or print it in logs. Back up the Keychain key securely; keep the same key for
future versions so installed applications can verify them.

Fork maintainers must generate their own key with Sparkle's `generate_keys`,
replace the public key, configure their repository secret, and change the GitHub
URLs in the build and feed scripts. Export/import options are documented by
`.build/artifacts/sparkle/Sparkle/bin/generate_keys --help`.

After packaging, `scripts/generate-update-feed.sh` signs the host architecture's
ZIP and produces `dist/appcast-arm64.xml` or `dist/appcast-x86_64.xml`. Locally it
uses the Keychain; CI passes the repository secret on stdin. A missing or
mismatched key prevents release publication. Both feeds are uploaded to the
GitHub Release, then the draft is published after every asset is available.
Installed apps read `releases/latest/download/appcast-<architecture>.xml`, so
prereleases are excluded. No separate hosting service is required.

The updater's full integration test needs a macOS GUI session:

```bash
python3 scripts/test-updater.py
```

It uses a local HTTP server, temporary application copies, a unique bundle ID
and an ephemeral key. It checks no-update and incompatible-OS cases, rejects
tampered feeds and archives, and performs a real replacement and relaunch.

## Publish

The GitHub workflow tests and packages Apple Silicon and Intel builds separately
on macOS 15 runners. The libraries are built for macOS 13 and cached per
architecture until `scripts/build-dependencies.sh` changes. Ordinary pushes and pull requests only produce workflow
artifacts. A version tag publishes a GitHub Release after **both** builds pass:

```bash
git tag -a v1.1 -m "Citrus Battery 1.1"
git push origin v1.1
```

The workflow uses GitHub's built-in token, with write access only in the release
job. The Sparkle signing secret is required; no Apple secrets are needed.
Versions starting with `0.` are marked as
prereleases on GitHub; numbered releases from `1.0` onward are regular releases. Review
[RELEASE-NOTES.md](RELEASE-NOTES.md) before tagging.

The first launch of a browser-downloaded archive must also be checked on a Mac
through the normal Gatekeeper prompt. A locally built app opening successfully
does not verify that download flow. Test Open at Login and notifications on the
installed app with their permissions enabled.
