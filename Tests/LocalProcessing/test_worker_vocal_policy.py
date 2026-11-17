"""Exercise the production worker's default stem policy without model inference."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

RESOURCE = Path(__file__).resolve().parents[2] / "Resources" / "LocalProcessing" / "worker.py"
SPEC = importlib.util.spec_from_file_location("reference_worker_policy_subject", RESOURCE)
subject = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(subject)


class FakeMIDI:
    def __init__(self):
        self.instruments = [SimpleNamespace(name="", pitch_bends=[], notes=[SimpleNamespace(pitch=45, start=0.1, end=0.5)])]

    def time_to_tick(self, value):
        return round(value * 480)

    def tick_to_time(self, value):
        return value / 480

    def write(self, destination):
        Path(destination).write_bytes(b"MThd")


class WorkerVocalPolicyTests(unittest.TestCase):
    def run_worker(self, include_vocals, negative_evidence=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = root / "inputs.json"
            inputs.write_text(json.dumps([{"name": name, "path": str(root / (name + ".wav"))}
                                          for name in ["bass", "other", "drums", "vocals"]]))
            called = []
            filtered = []
            def filter_notes(notes, source, vocals):
                filtered.append(notes)
                return [], len(notes)
            guard = SimpleNamespace(read_range=lambda *args: [0.0], filter_vocal_bleed=filter_notes)

            def predict(path, **kwargs):
                called.append(Path(path).stem)
                return {}, FakeMIDI(), [object()]

            inference = SimpleNamespace(Model=lambda _: object(), predict=predict)
            modules = {"basic_pitch": SimpleNamespace(inference=inference), "basic_pitch.inference": inference,
                       "soundfile": SimpleNamespace()}
            args = SimpleNamespace(inputs=str(inputs), output=str(root / "output"), maximum_bytes=1024,
                                   include_vocals=include_vocals, resources="unused-resources",
                                   vocal_reference=str(root / "vocals.wav") if negative_evidence else None)
            with patch.dict(sys.modules, modules), patch.object(subject, "check_audio", return_value=SimpleNamespace(duration=1)), \
                    patch.object(subject, "emit"), patch.object(subject, "load_reconstruction", return_value=guard):
                result = subject.transcribe(args, "unused-model")
            return called, [item["name"] for item in result], filtered

    def test_vocals_remain_untranscribed_by_default(self):
        called, artifacts, _ = self.run_worker(False)
        self.assertEqual(called, ["bass", "other"])
        self.assertEqual(artifacts, ["bass", "other"])

    def test_excluded_vocal_audio_is_negative_evidence_only(self):
        called, artifacts, filtered = self.run_worker(False, negative_evidence=True)
        self.assertEqual(called, ["bass", "other"])
        self.assertEqual(artifacts, [])
        self.assertEqual(len(filtered), 2)
        self.assertTrue(all(notes[0]["pitch"] == 45 for notes in filtered))

    def test_explicit_conversion_does_not_filter_user_requested_vocal_notes(self):
        called, artifacts, filtered = self.run_worker(True, negative_evidence=True)
        self.assertEqual(called, ["bass", "other", "vocals"])
        self.assertEqual(artifacts, ["vocals"])
        self.assertEqual(len(filtered), 2)  # Instrumental parts are still challenged; the vocal part is untouched.

    def test_explicit_host_flag_can_extract_vocal_melody(self):
        called, artifacts, _ = self.run_worker(True)
        self.assertEqual(called, ["bass", "other", "vocals"])
        self.assertEqual(artifacts, ["bass", "other", "vocals"])


if __name__ == "__main__":
    unittest.main()
