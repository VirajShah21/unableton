#!/usr/bin/env python3
"""Bounded, offline Demucs/Basic Pitch worker. All paths come from the host."""
import argparse
import contextlib
import fcntl
import hashlib
import importlib.metadata
import importlib.util
import json
import math
import os
from pathlib import Path
import socket
import sys
import sysconfig

# Helper modules live in the signed app bundle. Never write bytecode there.
sys.dont_write_bytecode = True


def emit(**value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_digest(path):
    h = hashlib.sha256()
    for file in sorted(path.rglob("*")):
        if file.is_symlink():
            raise ValueError("The local model contains an unsupported link.")
        if file.is_file():
            h.update(str(file.relative_to(path)).encode() + b"\0" + bytes.fromhex(digest(file)))
    return h.hexdigest()


def no_network():
    original_connect = socket.socket.connect
    def connect(self, address):
        if self.family in (socket.AF_INET, socket.AF_INET6):
            raise OSError("Networking is disabled during local song processing.")
        return original_connect(self, address)
    socket.socket.connect = connect
    socket.create_connection = lambda *a, **k: (_ for _ in ()).throw(OSError("Local processing is offline."))
    socket.getaddrinfo = lambda *a, **k: (_ for _ in ()).throw(OSError("Local processing is offline."))


def verify(root, resources, require_ready=True):
    manifest = json.loads((resources / "manifest.json").read_text())
    if require_ready:
        ready = json.loads((root / "ready.json").read_text())
        if ready.get("profile") != manifest["profile"] or ready.get("requirements_sha256") != digest(resources / "requirements.lock"):
            raise ValueError("Local processing needs setup for this app version.")
    for name, version in [("demucs", "4.0.1"), ("basic-pitch", "0.4.0"), ("torch", "2.5.1"), ("torchaudio", "2.5.1")]:
        if importlib.metadata.version(name) != version:
            raise ValueError("The local processing runtime has changed. Run Setup Local Processing again.")
    model = root / "models" / "demucs" / manifest["demucs"]["file"]
    if model.is_symlink() or model.stat().st_size != manifest["demucs"]["bytes"] or digest(model) != manifest["demucs"]["sha256"]:
        raise ValueError("The Demucs weights failed verification. Run Setup Local Processing again.")
    basic = Path(sysconfig.get_paths()["purelib"]) / "basic_pitch" / "saved_models" / manifest["basic_pitch"]["model"]
    if basic.is_symlink() or tree_digest(basic) != manifest["basic_pitch"]["tree_sha256"]:
        raise ValueError("The Basic Pitch weights failed verification. Run Setup Local Processing again.")
    return manifest, model, basic


def check_audio(path, sf):
    if path.is_symlink() or not path.is_file():
        raise ValueError("The audio source is not a regular file.")
    info = sf.info(str(path))
    if info.frames <= 0 or info.channels not in (1, 2) or not 8000 <= info.samplerate <= 192000 or info.duration > 600.001:
        raise ValueError("Local processing accepts up to ten minutes of mono/stereo audio.")
    return info


def separate(args, manifest):
    import numpy as np
    import soundfile as sf
    import torch
    import torchaudio
    from demucs.apply import apply_model
    from demucs.pretrained import get_model
    source = Path(args.source)
    info = check_audio(source, sf)
    rate = 44100
    frames = round(info.frames * rate / info.samplerate)
    required = frames * 2 * 4 * 4 + 16384
    if required > args.maximum_bytes:
        raise ValueError("The separated stems exceed the processing storage allowance. Use a shorter song.")
    torch.set_num_threads(min(4, max(1, os.cpu_count() or 1)))
    emit(status="Loading Demucs locally…")
    model = get_model(manifest["demucs"]["signature"], repo=Path(args.root) / "models" / "demucs")
    model.to("cpu").eval()
    names = list(model.sources)
    if set(names) != {"drums", "bass", "other", "vocals"}:
        raise ValueError("The installed Demucs model has unexpected stems.")
    # First pass computes one consistent normalization without retaining the song.
    total = 0.0
    squares = 0.0
    count = 0
    with sf.SoundFile(str(source)) as reader:
        for block in reader.blocks(blocksize=65536, dtype="float32", always_2d=True):
            samples = block.astype(np.float64, copy=False).reshape(-1)
            total += samples.sum()
            squares += np.dot(samples, samples)
            count += samples.size
    mean = total / max(1, count)
    scale = math.sqrt(max(1e-16, squares / max(1, count) - mean * mean))
    step = 30 * rate
    context = 2 * rate
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    writers = {}
    success = False
    try:
        for name in names:
            path = output / (name + ".wav")
            if path.exists():
                raise ValueError("The stem destination already contains output.")
            writers[name] = sf.SoundFile(str(path), "w", samplerate=rate, channels=2, format="WAV", subtype="FLOAT")
        with sf.SoundFile(str(source)) as reader, torch.inference_mode():
            for start in range(0, frames, step):
                end = min(frames, start + step)
                window_start = max(0, start - context)
                window_end = min(frames, end + context)
                source_start = round(window_start * info.samplerate / rate)
                source_end = min(info.frames, round(window_end * info.samplerate / rate))
                reader.seek(source_start)
                block = reader.read(source_end - source_start, dtype="float32", always_2d=True)
                if not np.isfinite(block).all():
                    raise ValueError("The song contains invalid samples.")
                if info.channels == 1:
                    block = np.repeat(block, 2, axis=1)
                tensor = torch.from_numpy(block.T.copy())
                if info.samplerate != rate:
                    tensor = torchaudio.functional.resample(tensor, info.samplerate, rate)
                expected = window_end - window_start
                tensor = torch.nn.functional.pad(tensor[..., :expected], (0, max(0, expected - tensor.shape[-1])))
                normalized = (tensor - mean) / scale
                emit(status="Separating stems locally · %d%%" % round(start / max(1, frames) * 100))
                stems = apply_model(model, normalized[None], device="cpu", split=True, shifts=0, overlap=0.25, progress=False, num_workers=0)[0]
                stems *= scale
                stems[names.index("other")] += mean
                left = start - window_start
                for index, name in enumerate(names):
                    samples = stems[index, :, left:left + end - start].T.contiguous().numpy()
                    if samples.shape != (end - start, 2) or not np.isfinite(samples).all():
                        raise ValueError("Demucs returned invalid or incomplete audio.")
                    writers[name].write(samples)
                del stems, normalized, tensor, block
        success = True
    finally:
        for writer in writers.values():
            writer.close()
        if not success:
            for name in names:
                (output / (name + ".wav")).unlink(missing_ok=True)
    emit(status="Local stems ready")
    return [{"name": name, "file": name + ".wav"} for name in names]


def load_reconstruction(resources):
    helper = Path(resources) / "reconstruction.py"
    spec = importlib.util.spec_from_file_location("unableton_reconstruction", helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def transcribe(args, basic):
    import soundfile as sf
    from basic_pitch.inference import Model, predict
    sources = json.loads(Path(args.inputs).read_text())
    if not isinstance(sources, list) or not 1 <= len(sources) <= 4:
        raise ValueError("Choose a bounded set of separated stems.")
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    emit(status="Loading Basic Pitch locally…")
    model = Model(basic)
    artifacts = []
    vocal_reference = getattr(args, "vocal_reference", None)
    guard = load_reconstruction(args.resources) if vocal_reference else None
    vocal_audio = None
    vocal_info = None
    if guard is not None:
        vocal_info = check_audio(Path(vocal_reference), sf)
        vocal_audio = guard.read_range(Path(vocal_reference), 0, vocal_info.duration)
    for value in sources:
        name = value.get("name")
        if name == "drums" or (name == "vocals" and not args.include_vocals):
            continue
        if name not in {"bass", "other", "vocals"}:
            raise ValueError("Choose a returned melodic stem for transcription.")
        path = Path(value["path"])
        info = check_audio(path, sf)
        emit(status="Transcribing %s with Basic Pitch…" % name)
        _, midi, events = predict(path, model_or_model_path=model, multiple_pitch_bends=False)
        if not events:
            continue
        if len(events) > 65536:
            raise ValueError("The detected part exceeds 65,536 notes. Use a shorter source.")
        # Model windows are padded. Never publish notes from padding or beyond the
        # source; round the upper bound down to an encodable MIDI tick.
        last_tick = int(midi.time_to_tick(info.duration))
        while last_tick > 0 and midi.tick_to_time(last_tick) > info.duration:
            last_tick -= 1
        last_time = midi.tick_to_time(last_tick)
        for instrument in midi.instruments:
            instrument.name = name
            instrument.pitch_bends = []
            instrument.notes = [note for note in instrument.notes if 0 <= note.start < last_time]
            for note in instrument.notes:
                note.end = min(note.end, last_time)
            instrument.notes = [note for note in instrument.notes if note.end > note.start]
        if guard is not None and name in {"bass", "other"}:
            if abs(info.duration - vocal_info.duration) > 0.025:
                raise ValueError("The vocal comparison stem does not align with the source.")
            source_audio = guard.read_range(path, 0, info.duration)
            proposed = [{"pitch": note.pitch, "startSeconds": note.start, "durationSeconds": note.end - note.start,
                         "_midi_note": note} for instrument in midi.instruments for note in instrument.notes]
            retained, rejected = guard.filter_vocal_bleed(proposed, source_audio, vocal_audio)
            identities = {id(note["_midi_note"]) for note in retained}
            for instrument in midi.instruments:
                instrument.notes = [note for note in instrument.notes if id(note) in identities]
            if rejected:
                emit(status="Excluded %d vocal-leak note estimates from %s" % (rejected, name))
        if not any(instrument.notes for instrument in midi.instruments):
            continue
        destination = output / (name + ".mid")
        if destination.exists():
            raise ValueError("The MIDI destination already contains output.")
        midi.write(str(destination))
        if sum((output / a["file"]).stat().st_size for a in artifacts) + destination.stat().st_size > args.maximum_bytes:
            destination.unlink()
            raise ValueError("The extracted MIDI exceeds the storage allowance.")
        artifacts.append({"name": name, "file": name + ".mid"})
    emit(status="Local note transcription ready")
    return artifacts


def main():
    try:
        os.setsid()
    except PermissionError:
        pass
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("separate", "transcribe", "reconstruct", "verify"))
    parser.add_argument("--root", required=True)
    parser.add_argument("--resources", required=True)
    parser.add_argument("--source")
    parser.add_argument("--include-vocals", action="store_true", help="Host-authorized vocal melody conversion only.")
    parser.add_argument("--vocal-reference", help="Excluded aligned stem for negative evidence only.")
    parser.add_argument("--inputs")
    parser.add_argument("--output")
    parser.add_argument("--start-seconds", type=float, default=0)
    parser.add_argument("--end-seconds", type=float)
    parser.add_argument("--maximum-bytes", type=int, default=4 * 1024 ** 3)
    args = parser.parse_args()
    if not 0 < args.maximum_bytes <= 4 * 1024 ** 3:
        raise ValueError("Invalid processing storage allowance.")
    root = Path(args.root)
    emit(status="Waiting for local processing…")
    with (root / "operation.lock").open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        no_network()
        manifest, _, basic = verify(root, Path(args.resources))
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TORCH_HOME"] = str(root / "models")
        # Third-party diagnostics go to stderr; stdout is only bounded JSON.
        with contextlib.redirect_stdout(sys.stderr):
            if args.operation == "verify":
                result = []
            elif args.operation == "separate":
                result = separate(args, manifest)
            elif args.operation == "reconstruct":
                result = load_reconstruction(args.resources).reconstruct(args, basic, emit, check_audio)
            else:
                result = transcribe(args, basic)
        emit(result={"artifacts": result})


if __name__ == "__main__":
    # Keep progress JSON separate even while package inference prints diagnostics.
    original_stdout = sys.stdout
    def emit(**value):
        print(json.dumps(value, separators=(",", ":")), file=original_stdout, flush=True)
    try:
        main()
    except BaseException as error:
        emit(error=str(error)[:1200])
        sys.exit(1)
