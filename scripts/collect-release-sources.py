#!/usr/bin/env python3
"""Collect verified upstream sources and build metadata for bundled libraries."""

import hashlib
import json
from pathlib import Path
import shutil
import sys
import urllib.request


def collect(licenses: Path, destination: Path) -> None:
    destination.mkdir(parents=True)
    for dependency in licenses.iterdir():
        if dependency.is_dir() and not (dependency / "sbom.spdx.json").is_file():
            raise RuntimeError(f"Missing source metadata for {dependency.name}")
    manifests = sorted(licenses.glob("*/sbom.spdx.json"))
    if not manifests:
        raise RuntimeError("No bundled dependency source metadata found")
    for manifest in manifests:
        metadata = json.loads(manifest.read_text())
        sources = [
            package for package in metadata["packages"]
            if package["SPDXID"].startswith("SPDXRef-Archive-")
        ]
        if not sources:
            raise RuntimeError(f"No source archive recorded in {manifest}")
        target = destination / manifest.parent.name
        shutil.copytree(manifest.parent, target)
        for index, source in enumerate(sources):
            url = source["downloadLocation"]
            checksum = next(
                value["checksumValue"] for value in source["checksums"]
                if value["algorithm"] == "SHA256"
            )
            if not url.startswith("https://"):
                raise RuntimeError(f"Expected an HTTPS source archive: {url}")
            filename = target / f"upstream-{index}-{Path(url.split('?')[0]).name}"
            digest = hashlib.sha256()
            print(f"Downloading source for {source['name']} {source['versionInfo']}", flush=True)
            with urllib.request.urlopen(url, timeout=120) as response, filename.open("wb") as output:
                if not response.url.startswith("https://"):
                    raise RuntimeError(f"Source download redirected away from HTTPS: {url}")
                while chunk := response.read(1024 * 1024):
                    digest.update(chunk)
                    output.write(chunk)
            if digest.hexdigest().lower() != checksum.lower():
                filename.unlink()
                raise RuntimeError(f"SHA256 mismatch for {url}")


if __name__ == "__main__":
    collect(Path(sys.argv[1]), Path(sys.argv[2]))
