#!/usr/bin/env python3
"""Install the exact factory SF2 files pinned in Resources/factory-manifest.json."""
from pathlib import Path
import hashlib
import json
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "factory"

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((ROOT / "Resources" / "factory-manifest.json").read_text())
    for entry in manifest:
        target = CACHE / entry["file"]
        if target.exists() and sha256(target) == entry["sha256"]:
            continue
        archive = CACHE / entry["url"].rsplit("/", 1)[-1]
        if not archive.exists() or sha256(archive) != entry["archiveSHA256"]:
            print("Downloading " + entry["name"], flush=True)
            temporary = archive.with_name(archive.name + ".download")
            try:
                request = urllib.request.Request(entry["url"], headers={"User-Agent": "Unableton-factory-setup/0.1"})
                with urllib.request.urlopen(request, timeout=90) as response, temporary.open("wb") as output:
                    while block := response.read(1024 * 1024):
                        output.write(block)
                if sha256(temporary) != entry["archiveSHA256"]:
                    raise RuntimeError("Download checksum mismatch: " + entry["name"])
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
        temporary = target.with_suffix(".tmp")
        try:
            # Extract one known file into a controlled destination. No archive paths are installed.
            with temporary.open("wb") as output:
                subprocess.run(["/usr/bin/tar", "-xOf", str(archive), entry["member"]], stdout=output, check=True)
            if sha256(temporary) != entry["sha256"]:
                raise RuntimeError("Instrument checksum mismatch: " + entry["name"])
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
        print("Installed " + entry["name"], flush=True)
    print("Factory instruments ready.")

if __name__ == "__main__":
    main()
