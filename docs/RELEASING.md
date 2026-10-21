# GitHub releases

The public repository is [rdna897/citrus-battery](https://github.com/rdna897/citrus-battery).
Distribution uses GitHub Releases with ad hoc signing (`codesign --sign -`).
It needs no Apple Developer account, signing certificate, provisioning profile,
or notarization credentials. Users approve the first launch as described in
[INSTALL.md](INSTALL.md).

## Build and validate

Install the dependencies from the README and commit the release changes. Then:

```bash
swift test
VERSION=0.1.0 ./scripts/package-release.sh
```

Packaging requires a clean checkout, builds the app for the host architecture,
verifies the app signature, checks that bundled libraries include that
architecture, and rejects remaining external Homebrew links. The app declares
the highest minimum macOS version required by its executable and bundled
libraries. Building on a newer Mac can produce a higher minimum version.

The archives in `dist/` contain the app and installation instructions, matching
source code and dependency sources, licenses, build metadata, and SHA-256 files.
Upstream source downloads are checked against the hashes in Homebrew's SBOMs.
Packaging stops if the source metadata or a source download cannot be verified.

## Publish

The GitHub workflow tests and packages Apple Silicon and Intel builds separately
on macOS 15 runners. Ordinary pushes and pull requests only produce workflow
artifacts. A version tag publishes a GitHub Release after **both** builds pass:

```bash
git tag -a v0.1.0 -m "Citrus Battery 0.1.0"
git push origin v0.1.0
```

The workflow uses GitHub's built-in token, with write access only in the release
job. No Apple secrets are needed. Versions starting with `0.` and versions with
a prerelease suffix are marked as prereleases on GitHub. Review
[RELEASE-NOTES.md](RELEASE-NOTES.md) before tagging.

The first launch of a browser-downloaded archive must also be checked on a Mac
through the normal Gatekeeper prompt. A locally built app opening successfully
does not verify that download flow. Test Open at Login and notifications on the
installed app with their permissions enabled.
