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

The separate build number identifies a particular build. GitHub uses the workflow
run number, and local builds use the commit count unless `BUILD` is specified.
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
architecture, and rejects remaining external Homebrew links. The app declares
the highest minimum macOS version required by its executable and bundled
libraries. Building on a newer Mac can produce a higher minimum version.

Packaging also runs the extracted app through normal GUI startup. It must finish
reading notification settings and open a visible application window, then exit
cleanly. This check exercises code that the command-line diagnostics do not run.
To run it separately on a built app:

```bash
python3 scripts/test-app-launch.py "dist/Citrus Battery.app"
```

The archives in `dist/` contain the app and installation instructions, matching
source code and dependency sources, licenses, build metadata, and SHA-256 files.
Upstream source downloads are checked against the hashes in Homebrew's SBOMs.
Packaging stops if the source metadata or a source download cannot be verified.

## Publish

The GitHub workflow tests and packages Apple Silicon and Intel builds separately
on macOS 15 runners. Ordinary pushes and pull requests only produce workflow
artifacts. A version tag publishes a GitHub Release after **both** builds pass:

```bash
git tag -a v1.0.1 -m "Citrus Battery 1.0.1"
git push origin v1.0.1
```

The workflow uses GitHub's built-in token, with write access only in the release
job. No Apple secrets are needed. Versions starting with `0.` are marked as
prereleases on GitHub; numbered releases from `1.0` onward are regular releases. Review
[RELEASE-NOTES.md](RELEASE-NOTES.md) before tagging.

The first launch of a browser-downloaded archive must also be checked on a Mac
through the normal Gatekeeper prompt. A locally built app opening successfully
does not verify that download flow. Test Open at Login and notifications on the
installed app with their permissions enabled.
