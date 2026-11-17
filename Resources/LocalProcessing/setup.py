#!/usr/bin/env python3
"""Explicit local-model installation. Never invoked by a build or app startup."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import urllib.request


def emit(**value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def run(arguments, environment):
    # Package manager diagnostics are drained by the host, separately from progress JSON.
    subprocess.run(arguments, env=environment, stdout=sys.stderr, stderr=sys.stderr, check=True)


def main():
    try:
        os.setsid()
    except PermissionError:
        pass
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--resources", required=True)
    parser.add_argument("--uv", required=True)
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise ValueError("This local processing profile requires an Apple Silicon Mac (macOS arm64).")
    root = Path(args.root)
    resources = Path(args.resources)
    manifest = json.loads((resources / "manifest.json").read_text())
    uv = Path(args.uv)
    if not uv.is_file() or not os.access(uv, os.X_OK):
        raise ValueError("Install uv from https://docs.astral.sh/uv/getting-started/installation/ and run setup again.")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / "operation.lock").open("a") as lock:
        emit(status="Waiting to set up local processing…")
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        (root / "ready.json").unlink(missing_ok=True)
        environment = dict(os.environ)
        environment.update(UV_PYTHON_INSTALL_DIR=str(root / "python"), UV_CACHE_DIR=str(root / "download-cache"), UV_NO_PROGRESS="1")
        emit(status="Installing Python %s for local processing…" % manifest["python"])
        run([str(uv), "python", "install", "--no-bin", manifest["python"]], environment)
        virtualenv = root / "environment"
        python = virtualenv / "bin" / "python"
        # Keep the interpreter inside the managed runtime, including after packaging.
        if virtualenv.exists() and (not python.exists() or not python.resolve().is_relative_to(root / "python")):
            shutil.rmtree(virtualenv)
        if not python.exists():
            run([str(uv), "venv", "--python", manifest["python"], str(virtualenv)], environment)
        emit(status="Installing pinned Demucs and Basic Pitch packages…")
        # Reinstall the small model-bearing wheel so explicit Repair also fixes same-version damage.
        run([str(uv), "pip", "sync", "--python", str(python), "--require-hashes", "--reinstall-package", "basic-pitch", str(resources / "requirements.lock")], environment)
        model = manifest["demucs"]
        destination = root / "models" / "demucs" / model["file"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        valid = destination.is_file() and not destination.is_symlink() and destination.stat().st_size == model["bytes"] and digest(destination) == model["sha256"]
        if not valid:
            emit(status="Downloading the pinned Demucs weights (84 MB)…")
            temporary = destination.with_suffix(".part")
            try:
                request = urllib.request.Request(model["url"], headers={"User-Agent": "Unableton-LocalProcessing/1"})
                with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
                    if response.geturl() != model["url"] or response.status != 200:
                        raise ValueError("The model server returned an unexpected response.")
                    total = 0
                    while True:
                        block = response.read(1024 * 1024)
                        if not block:
                            break
                        total += len(block)
                        if total > model["bytes"]:
                            raise ValueError("The model download exceeded its pinned size.")
                        output.write(block)
                if total != model["bytes"] or digest(temporary) != model["sha256"]:
                    raise ValueError("The Demucs weights failed the pinned checksum.")
                temporary.replace(destination)
            finally:
                temporary.unlink(missing_ok=True)
        emit(status="Verifying local model weights…")
        ready = {"profile": manifest["profile"], "requirements_sha256": digest(resources / "requirements.lock")}
        marker = root / "ready.json"
        try:
            validation = "import importlib.util,sys; from pathlib import Path; p=Path(sys.argv[1]); s=importlib.util.spec_from_file_location('local_worker',p/'worker.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.verify(Path(sys.argv[2]),p,require_ready=False)"
            run([str(python), "-I", "-B", "-c", validation, str(resources), str(root)], environment)
        except BaseException:
            marker.unlink(missing_ok=True)
            raise
        temporary_marker = root / "ready.partial"
        temporary_marker.write_text(json.dumps(ready))
        temporary_marker.replace(marker)
        # The wheel cache is useful only during setup; leave the installed runtime and models.
        shutil.rmtree(root / "download-cache", ignore_errors=True)
        emit(status="Local processing is ready")
        emit(result={"artifacts": []})


if __name__ == "__main__":
    try:
        main()
    except BaseException as error:
        emit(error=str(error)[:1200])
        sys.exit(1)
