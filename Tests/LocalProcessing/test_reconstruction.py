"""Run with the managed local-processing Python. No network or downloads."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import numpy as np

RESOURCE = Path(__file__).resolve().parents[2] / "Resources" / "LocalProcessing" / "reconstruction.py"
SPEC = importlib.util.spec_from_file_location("reconstruction_test_subject", RESOURCE)
subject = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(subject)
RATE = subject.RATE


def tone(duration, frequency, amplitude=0.3):
    return (amplitude * np.sin(np.arange(round(duration * RATE)) * 2 * np.pi * frequency / RATE)).astype(np.float32)


class ReconstructionTests(unittest.TestCase):
    def test_opposite_phase_stereo_is_not_erased(self):
        audio = tone(0.5, 220)
        stereo = np.stack((audio, -audio), axis=1)
        self.assertGreater(subject.rms(subject.mono(stereo)), 0.2)

    def test_quiet_separator_leakage_does_not_become_bass(self):
        notes = subject.bass_notes(tone(2, 110, 0.00001), 0, 0.3, lambda **_: None)
        self.assertEqual(notes, [])

    def test_bass_measures_fundamental_and_keeps_silent_intro(self):
        audio = np.zeros(RATE * 3, np.float32)
        audio[RATE:round(RATE * 2.5)] = tone(1.5, 110)
        notes = subject.bass_notes(audio, 4, 0.3, lambda **_: None)
        self.assertTrue(notes)
        self.assertTrue(all(note["pitch"] == 45 for note in notes))
        self.assertGreaterEqual(notes[0]["startSeconds"], 4.9)
        self.assertLess(notes[-1]["startSeconds"] + notes[-1]["durationSeconds"], 6.65)
        for previous, current in zip(notes, notes[1:]):
            self.assertLessEqual(previous["startSeconds"] + previous["durationSeconds"], current["startSeconds"] + 0.001)

    def test_accompaniment_rejects_silent_and_wrong_pitch_proposals(self):
        audio = np.zeros(RATE * 3, np.float32)
        audio[RATE:RATE * 2] = tone(1, 220)
        events = [(0.1, 0.5, 57, 0.9, None), (1, 2, 57, 0.8, None), (1, 2, 88, 0.9, None)]
        with tempfile.TemporaryDirectory() as directory, patch("basic_pitch.inference.predict", return_value=({}, None, events)) as predict:
            notes, proposals = subject.accompaniment(audio, object(), Path(directory), 5, 0.3, lambda **_: None)
        self.assertEqual(proposals, 3)
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0]["pitch"], 57)
        self.assertLess(abs(notes[0]["startSeconds"] - 6), 0.06)
        self.assertEqual(predict.call_args.kwargs["melodia_trick"], False)
        self.assertFalse((Path(directory) / "model-input.wav").exists())

    def test_velocity_follows_audio_level_instead_of_model_activation(self):
        audio = np.concatenate((tone(1, 220, 0.3), tone(1, 220, 0.03)))
        notes = [{"pitch": 57, "startSeconds": 0, "durationSeconds": 1, "velocity": 1},
                 {"pitch": 57, "startSeconds": 1, "durationSeconds": 1, "velocity": 1}]
        subject.assign_velocities(notes, audio, 0)
        self.assertGreater(notes[0]["velocity"], notes[1]["velocity"] * 2)
        self.assertAlmostEqual(notes[0]["velocity"] / notes[1]["velocity"], 10, delta=0.7)

    def test_vocal_leak_is_excluded_without_transcribing_the_vocal_stem(self):
        time = np.arange(RATE * 3) / RATE
        envelope = np.maximum(0, np.sin(np.pi * time)) ** 2
        vocal = ((tone(3, 220) + tone(3, 440, 0.15) + tone(3, 660, 0.08)) * envelope).astype(np.float32)
        leak = vocal * 0.12
        note = {"pitch": 57, "startSeconds": 0.2, "durationSeconds": 2.6, "velocity": 90}
        kept, removed = subject.filter_vocal_bleed([note], leak, vocal)
        self.assertEqual(removed, 1)
        self.assertEqual(kept, [])

    def test_same_pitch_instrument_with_independent_envelope_survives_vocal_comparison(self):
        time = np.arange(RATE * 3) / RATE
        voice_envelope = np.exp(-((time - 0.65) / 0.18) ** 2) + np.exp(-((time - 2.35) / 0.18) ** 2)
        vocal = (tone(3, 220) * voice_envelope * 5).astype(np.float32)
        instrument_envelope = np.exp(-((time - 1.5) / 0.45) ** 2)
        instrument = (tone(3, 220) * instrument_envelope).astype(np.float32)
        note = {"pitch": 57, "startSeconds": 0.2, "durationSeconds": 2.6, "velocity": 90}
        kept, removed = subject.filter_vocal_bleed([note], instrument, vocal)
        self.assertEqual(removed, 0)
        self.assertEqual(kept, [note])

    def test_strong_unison_instrument_and_independent_octave_survive_vocal_comparison(self):
        vocal = tone(3, 220)
        audio = tone(3, 220, 0.5) + tone(3, 440, 0.12)
        notes = [{"pitch": pitch, "startSeconds": 0.2, "durationSeconds": 2.6, "velocity": 90} for pitch in (57, 69)]
        kept, removed = subject.filter_vocal_bleed(notes, audio, vocal)
        self.assertEqual(removed, 0)
        self.assertEqual(kept, notes)

    def test_drum_velocity_uses_global_class_amplitude_not_onset_strength(self):
        notes = [{"pitch": pitch, "_loudness": amplitude} for pitch in (36, 42) for amplitude in (0.3, 0.03)]
        subject.assign_drum_velocities(notes)
        self.assertAlmostEqual(notes[0]["velocity"] / notes[1]["velocity"], 10, delta=0.7)
        self.assertEqual([n["velocity"] for n in notes[:2]], [n["velocity"] for n in notes[2:]])

    def test_coherent_bass_third_harmonic_does_not_become_an_extra_instrument(self):
        bass = tone(3, 110) + tone(3, 330, 0.15)
        other = tone(3, 330, 0.015)
        source = [{"pitch": 45, "startSeconds": 0.1, "durationSeconds": 2.8}]
        note = {"pitch": 64, "startSeconds": 0.2, "durationSeconds": 2.6, "velocity": 30}
        kept, removed = subject.filter_bass_harmonics([note], other, bass, source)
        self.assertEqual(removed, 1)
        self.assertEqual(kept, [])

    def test_harmonic_interval_alone_cannot_remove_an_independent_instrument(self):
        time = np.arange(RATE * 3) / RATE
        bass_envelope = np.exp(-((time - 0.65) / 0.18) ** 2) + np.exp(-((time - 2.35) / 0.18) ** 2)
        bass = ((tone(3, 110) + tone(3, 330, 0.15)) * bass_envelope).astype(np.float32)
        other = (tone(3, 330, 0.12) * np.exp(-((time - 1.5) / 0.45) ** 2)).astype(np.float32)
        source = [{"pitch": 45, "startSeconds": 0.1, "durationSeconds": 2.8}]
        note = {"pitch": 64, "startSeconds": 0.2, "durationSeconds": 2.6, "velocity": 90}
        kept, removed = subject.filter_bass_harmonics([note], other, bass, source)
        self.assertEqual(removed, 0)
        self.assertEqual(kept, [note])

    def test_bass_analysis_windows_preserve_long_sustains_without_overlap(self):
        windows = []
        def measured(values, offset, level, emit):
            windows.append(len(values) / RATE)
            return [{"pitch": 45, "startSeconds": offset, "durationSeconds": len(values) / RATE, "velocity": 80}]
        with patch.object(subject, "_bass_window", side_effect=measured):
            notes = subject.bass_notes(tone(48, 110), 7, 0.3, lambda **_: None)
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0]["startSeconds"], 7)
        self.assertEqual(notes[0]["durationSeconds"], 48)
        self.assertLessEqual(max(windows), 26)

    def test_bass_attack_backtracking_is_invariant_to_source_window_offset(self):
        # A measured attack can precede pYIN's late pitch transition and trim
        # the preceding hold. Local/absolute time must not change that edit.
        audio = np.zeros(RATE * 3, np.float32)
        audio[round(RATE * 0.5):round(RATE * 1.3)] = tone(0.8, 110)
        audio[round(RATE * 1.3):round(RATE * 2.3)] = tone(1, 82.4069)
        with patch.object(subject, "measured_attack", side_effect=lambda audio, start, threshold: max(0, start - 0.15)):
            zero = subject._bass_window(audio, 0, 0.3, lambda **_: None)
            shifted = subject._bass_window(audio, 23, 0.3, lambda **_: None)
        self.assertGreaterEqual(len(zero), 2)
        self.assertEqual(len(zero), len(shifted))
        for first, second in zip(zero, shifted):
            self.assertEqual(first["pitch"], second["pitch"])
            self.assertAlmostEqual(first["startSeconds"], second["startSeconds"] - 23)
            self.assertAlmostEqual(first["durationSeconds"], second["durationSeconds"])
            self.assertGreater(second["durationSeconds"], 0)

    def test_accompaniment_window_context_does_not_cut_a_long_hold(self):
        import soundfile as sf
        audio = tone(48, 220)
        def prediction(path, **_):
            return {}, None, [(0, sf.info(path).duration, 57, 0.8, None)]
        with tempfile.TemporaryDirectory() as directory, patch("basic_pitch.inference.predict", side_effect=prediction):
            notes, _ = subject.accompaniment(audio, object(), Path(directory), 0, 0.3, lambda **_: None)
        self.assertEqual(len(notes), 1)
        self.assertLess(notes[0]["startSeconds"], 0.03)
        self.assertGreater(notes[0]["startSeconds"] + notes[0]["durationSeconds"], 47.95)

    def test_measured_drum_classes_keep_source_attack_times(self):
        from scipy.signal import butter, sosfilt
        audio = np.zeros(RATE * 3, np.float32)
        length = round(RATE * 0.15)
        time = np.arange(length) / RATE
        envelope = np.exp(-time * 35)
        rng = np.random.default_rng(17)
        kick = np.sin(2 * np.pi * 65 * time) * envelope
        snare = sosfilt(butter(3, [400, 3500], fs=RATE, btype="bandpass", output="sos"), rng.standard_normal(length)) * envelope
        hat = np.sin(2 * np.pi * 8200 * time) * np.exp(-time * 80)
        for start, value in [(0.75, kick), (1.25, snare), (1.75, hat)]:
            first = round(start * RATE)
            audio[first:first + length] += value.astype(np.float32) * 0.5
        notes, _, _ = subject.drum_notes(audio, 2, 0.3)
        for pitch, time in [(36, 2.75), (38, 3.25), (42, 3.75)]:
            matches = [n for n in notes if n["pitch"] == pitch and abs(n["startSeconds"] - time) < 0.04]
            self.assertTrue(matches, (pitch, notes))
        self.assertFalse(any(n["startSeconds"] < 2.65 for n in notes))

    def test_silence_produces_no_drum_pattern(self):
        notes, tempo, quality = subject.drum_notes(np.zeros(RATE * 2, np.float32), 0, 0.3)
        self.assertEqual(notes, [])
        self.assertIsNone(tempo)
        self.assertEqual(quality, 0)

    def test_half_and_double_time_windows_are_not_averaged(self):
        with patch.object(subject, "_drum_window", side_effect=[([], 80.0, 0.7), ([], 160.0, 0.9)]):
            _, tempo, quality = subject.drum_notes(np.zeros(RATE * 48, np.float32), 0, 0.3)
        self.assertEqual(tempo, 160.0)
        self.assertEqual(quality, 0.9)

    def test_bass_sound_has_no_default_wobble(self):
        parameters = subject.sound_parameters("bass", tone(1, 110), [{"durationSeconds": 0.5}])
        self.assertEqual(parameters["lfoDepth"], 0)
        self.assertEqual(parameters["detune"], 0)
        self.assertEqual(parameters["reverb"], 0)
        self.assertEqual(parameters["delay"], 0)

    def test_pitch_envelope_corrects_late_onset_and_excessive_hold(self):
        audio = np.zeros(RATE * 3, np.float32)
        audio[RATE:RATE * 2] = tone(1, 220)
        refined = subject.PitchEvidence(audio).refine(1.12, 2.3, 57)
        self.assertIsNotNone(refined)
        self.assertLess(abs(refined["start"] - 1), 0.06)
        self.assertLess(abs(refined["end"] - 2), 0.08)

    def test_upper_note_does_not_time_or_lengthen_a_lower_fundamental(self):
        audio = np.zeros(RATE * 3, np.float32)
        audio[round(RATE * 0.7):round(RATE * 1.4)] += tone(0.7, 220, 0.08)
        audio[round(RATE * 1.2):round(RATE * 2.1)] += tone(0.9, 440, 0.4)
        events = [(0.82, 1.7, 57, 0.9, None), (1.2, 2.1, 69, 0.3, None)]
        evidence = subject.PitchEvidence(audio, events)
        lower = evidence.refine(0.82, 1.7, 57)
        upper = evidence.refine(1.2, 2.1, 69)
        self.assertIsNotNone(lower)
        self.assertIsNotNone(upper)
        self.assertEqual(lower["basis"], "fundamental")
        self.assertLess(abs(lower["start"] - 0.7), 0.06)
        self.assertLess(abs(lower["end"] - 1.4), 0.08)
        self.assertLess(abs(upper["start"] - 1.2), 0.06)
        self.assertLess(abs(upper["end"] - 2.1), 0.08)
        proposals = [dict(pitch=pitch, startSeconds=start, durationSeconds=end-start, strength=strength, _modelStart=start)
                     for start, end, pitch, strength, _ in events]
        retained, _ = subject.harmonic_duplicates(proposals, evidence, 0)
        self.assertEqual(len(retained), 2)

    def test_one_upper_note_cannot_invent_its_submultiple(self):
        audio = np.zeros(RATE * 3, np.float32)
        audio[RATE:RATE * 2] = tone(1, 440)
        events = [(1, 2, 57, 0.8, None), (1, 2, 69, 0.9, None)]
        evidence = subject.PitchEvidence(audio, events)
        self.assertIsNone(evidence.refine(1, 2, 57))
        self.assertIsNotNone(evidence.refine(1, 2, 69))

    def test_missing_fundamental_requires_unexplained_partial_consensus(self):
        audio = np.zeros(RATE * 3, np.float32)
        audio[RATE:RATE * 2] = tone(1, 220, 0.25) + tone(1, 330, 0.2)
        missing = (1, 2, 45, 0.8, None)
        inferred = subject.PitchEvidence(audio, [missing]).refine(1, 2, 45)
        self.assertIsNotNone(inferred)
        self.assertEqual(inferred["basis"], "harmonic-consensus")
        explained = subject.PitchEvidence(audio, [missing, (1, 2, 57, 0.9, None), (1, 2, 64, 0.9, None)])
        self.assertIsNone(explained.refine(1, 2, 45))

    def test_amplitude_valley_does_not_cut_a_genuinely_held_note(self):
        audio = np.zeros(RATE * 4, np.float32)
        audio[round(RATE * 0.5):round(RATE * 3.5)] = tone(3, 220)
        audio[round(RATE * 2.4):round(RATE * 2.65)] *= 0.02
        refined = subject.PitchEvidence(audio).refine(0.5, 3.5, 57)
        self.assertIsNotNone(refined)
        self.assertLess(abs(refined["start"] - 0.5), 0.06)
        self.assertLess(abs(refined["end"] - 3.5), 0.08)

    def test_upper_attack_does_not_retrigger_a_continuous_lower_note(self):
        audio = tone(3, 220, 0.15)
        audio[RATE:round(RATE * 1.3)] += tone(0.3, 440, 0.4)
        events = [(0, 3, 57, 0.9, None), (1.0, 1.3, 57, 0.8, None), (1, 1.3, 69, 0.9, None)]
        with tempfile.TemporaryDirectory() as directory, patch("basic_pitch.inference.predict", return_value=({}, None, events)):
            notes, _ = subject.accompaniment(audio, object(), Path(directory), 0, 0.3, lambda **_: None)
        lower = [n for n in notes if n["pitch"] == 57]
        self.assertEqual(len(lower), 1)
        self.assertGreater(lower[0]["durationSeconds"], 2.9)
        self.assertEqual(len([n for n in notes if n["pitch"] == 69]), 1)

    def test_true_repeated_attack_survives_same_pitch_overlap(self):
        time = np.arange(RATE * 3) / RATE
        envelope = np.zeros(len(time))
        for start in (0.5, 1.2):
            active = time >= start
            envelope[active] += np.exp(-(time[active] - start) * 8)
        audio = (0.3 * envelope * np.sin(2*np.pi*220*time)).astype(np.float32)
        events = [(0.5, 1.25, 57, 0.9, None), (1.2, 2.0, 57, 0.9, None)]
        with tempfile.TemporaryDirectory() as directory, patch("basic_pitch.inference.predict", return_value=({}, None, events)):
            notes, _ = subject.accompaniment(audio, object(), Path(directory), 0, 0.3, lambda **_: None)
        self.assertEqual(len(notes), 2)
        self.assertLess(abs(notes[1]["startSeconds"] - 1.2), 0.06)

    def test_drum_class_controls_do_not_lowpass_hats_at_six_kilohertz(self):
        audio = tone(1, 8200)
        hat = subject.sound_parameters("drums", audio, [{"pitch": 42, "durationSeconds": 0.1}])
        kick = subject.sound_parameters("drums", audio, [{"pitch": 36, "durationSeconds": 0.14}])
        self.assertEqual(hat["cutoff"], 20000)
        self.assertLessEqual(kick["cutoff"], 2000)
        self.assertEqual(hat["attack"], 0.001)

    def test_reconstruction_splits_drum_classes_with_one_amplitude_budget(self):
        import soundfile as sf
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.wav"
            sf.write(source, tone(1, 220), RATE)
            inputs = root / "inputs.json"
            inputs.write_text(json.dumps([{"name": name, "path": str(source)} for name in ("bass", "other", "drums")]))
            notes = [{"pitch": pitch, "startSeconds": 0.2, "durationSeconds": 0.1,
                      "velocity": 90, "_loudness": level} for pitch, level in ((36, 4), (38, 2), (42, 1))]
            args = SimpleNamespace(inputs=str(inputs), start_seconds=0, end_seconds=1,
                output=str(root / "result"), maximum_bytes=1024 * 1024)
            with patch("basic_pitch.inference.Model", return_value=object()), \
                 patch.object(subject, "bass_notes", return_value=[]), \
                 patch.object(subject, "accompaniment", return_value=([], 0)), \
                 patch.object(subject, "drum_notes", return_value=(notes, None, 0)):
                subject.reconstruct(args, Path("unused-model"), lambda **_: None, lambda path, module: module.info(path))
            result = json.loads((root / "result" / "reconstruction.json").read_text())
        self.assertEqual(result["profile"], "local-reconstruction-v4")
        self.assertEqual([p["id"] for p in result["parts"]], ["drums_kick", "drums_snare", "drums_hat"])
        amplitudes = np.array([p["relativeGain"] for p in result["parts"]])
        self.assertAlmostEqual(float(np.sum(amplitudes * amplitudes)), 1)
        self.assertAlmostEqual(amplitudes[0] / amplitudes[1], 2)
        self.assertAlmostEqual(amplitudes[1] / amplitudes[2], 2)
        self.assertEqual(result["parts"][-1]["suggestedParameters"]["cutoff"], 20000)
        self.assertTrue(all(len(p["notes"]) == 1 for p in result["parts"]))

    def test_sequential_melody_is_not_split_just_for_more_instruments(self):
        notes = [{"pitch": pitch, "startSeconds": index, "durationSeconds": 0.3, "velocity": 90}
                 for index, pitch in enumerate([48, 60, 72, 84, 72, 60, 48, 60])]
        groups = subject.partition_accompaniment(notes)
        self.assertEqual(len(groups), 1)
        self.assertEqual(len(groups[0][2]), len(notes))

    def test_independent_voices_partition_notes_exactly_once(self):
        notes = []
        for index in range(8):
            notes.append({"pitch": 48 + (index % 2) * 3, "startSeconds": index * 0.5, "durationSeconds": 0.35, "velocity": 90})
            notes.append({"pitch": 72 + (index % 2) * 4, "startSeconds": index * 0.5 + 0.1, "durationSeconds": 0.35, "velocity": 60})
        groups = subject.partition_accompaniment(notes)
        self.assertEqual(len(groups), 2)
        assigned = [id(note) for _, _, group in groups for note in group]
        self.assertEqual(sorted(assigned), sorted(map(id, notes)))
        self.assertEqual(len(assigned), len(set(assigned)))
        self.assertLessEqual(len(groups), 6)

    def test_dense_pitch_sets_still_partition_independent_lines(self):
        notes = []
        for index in range(18):
            for register in (48, 60, 72):
                notes.append({"pitch": register + index % 12, "startSeconds": index * 0.4,
                              "durationSeconds": 0.3, "velocity": 80})
        groups = subject.partition_accompaniment(notes)
        self.assertGreater(len(groups), 1)
        self.assertLessEqual(len(groups), 6)
        self.assertEqual(sorted(id(n) for _, _, group in groups for n in group), sorted(map(id, notes)))
        reordered = subject.partition_accompaniment(list(reversed(notes)))
        signature = lambda result: [(name, [(n["pitch"], n["startSeconds"]) for n in selected]) for name, _, selected in result]
        self.assertEqual(signature(groups), signature(reordered))

    def test_weak_synchronous_harmonic_is_challenged_but_separate_attack_survives(self):
        audio = tone(2, 220) + tone(2, 440, 0.08)
        evidence = subject.PitchEvidence(audio)
        def note(pitch, start, strength):
            return {"pitch": pitch, "startSeconds": start, "durationSeconds": 1,
                    "_modelStart": start, "strength": strength}
        lower = note(57, 0.2, 0.9)
        weak_harmonic = note(69, 0.2, 0.3)
        measured = [lower, weak_harmonic]
        retained, _ = subject.harmonic_duplicates(measured, evidence, 0)
        self.assertEqual(len(retained), 1)
        independent = note(69, 0.4, 0.3)
        retained, _ = subject.harmonic_duplicates([lower, independent], evidence, 0)
        self.assertEqual(len(retained), 2)


if __name__ == "__main__":
    unittest.main()
