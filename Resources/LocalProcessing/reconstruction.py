"""Measured instrumental reconstruction; no song templates or network work.

Basic Pitch proposes accompaniment notes. Bass fundamentals and drum attacks
are checked in the separated audio. Detection strength is not audio loudness.
"""
import json
import math
from pathlib import Path

PROFILE = "local-reconstruction-v4"
RATE = 22050
MAX_NOTES = 65536


def rms(values):
    import numpy as np
    return float(np.sqrt(np.mean(np.square(values, dtype=np.float64)))) if len(values) else 0.0


def mono(values):
    import numpy as np
    if values.ndim == 1:
        return values
    combined = values.mean(axis=1)
    # Do not erase opposite-phase stereo with an unconditional average.
    if rms(combined) < rms(values.reshape(-1)) * 0.1:
        return values[:, int(np.argmax(np.mean(values * values, axis=0)))]
    return combined


def read_range(path, start, end):
    import librosa
    import numpy as np
    import soundfile as sf
    with sf.SoundFile(str(path)) as source:
        source.seek(round(start * source.samplerate))
        values = source.read(max(1, round((end - start) * source.samplerate)), dtype="float32", always_2d=True)
        if not np.isfinite(values).all():
            raise ValueError("The reference contains invalid samples.")
        result = mono(values)
        if source.samplerate != RATE:
            result = librosa.resample(result, orig_sr=source.samplerate, target_sr=RATE)
        return result.astype(np.float32, copy=False)


def frame_rms(audio, hop=256, length=1024):
    import librosa
    return librosa.feature.rms(y=audio, frame_length=length, hop_length=hop, center=True)[0]


def audible_threshold(audio, mixture_level):
    import numpy as np
    energy = frame_rms(audio)
    active = float(np.quantile(energy, 0.95)) if len(energy) else 0
    # Relative source energy rejects separator leakage before any normalization.
    return max(0.0001, mixture_level * 0.003, active * 0.018), active


def note_level(audio, start, end):
    import numpy as np
    left, right = max(0, round(start * RATE)), min(len(audio), round(end * RATE))
    if right <= left:
        return 0.0
    values = audio[left:right]
    energy = frame_rms(values, hop=128, length=min(1024, max(256, 2 ** int(math.log2(max(256, len(values)))))))
    return float(np.quantile(energy, 0.65)) if len(energy) else 0.0


def assign_velocities(notes, audio, offset):
    import numpy as np
    levels = [note_level(audio, n["startSeconds"] - offset, n["startSeconds"] + n["durationSeconds"] - offset) for n in notes]
    reference = float(np.quantile(levels, 0.9)) if levels else 0
    for note, level in zip(notes, levels):
        note["velocity"] = measured_velocity(level, reference)
    return notes


def measured_velocity(level, reference, nominal=104):
    """Preserve measured amplitude ratios for the linear built-in renderer.

    Taking the square root of an amplitude envelope boosts quiet leakage and
    flattens dynamics. Sample-bank velocity response can still differ; actual
    candidate renders, rather than these numbers alone, judge the sound fit.
    """
    return max(1, min(118, round(nominal * level / max(reference, 1e-9))))


def pitch_present(audio, start, end, pitch):
    """Reject model notes with no narrow-band harmonic evidence in the source."""
    import numpy as np
    from scipy.signal import periodogram
    left, right = max(0, round(start * RATE)), min(len(audio), round(end * RATE))
    if right - left < 128:
        return False
    # Check a bounded middle window, where the note should actually sustain.
    center = (left + right) // 2
    segment = audio[max(left, center - RATE // 4):min(right, center + RATE // 4)]
    frequencies, power = periodogram(segment, RATE, nfft=16384)
    f0 = 440 * 2 ** ((pitch - 69) / 12)
    matches = []
    for harmonic in (1, 2, 3):
        frequency = f0 * harmonic
        band = abs(frequencies - frequency) <= max(3.0, frequency * 0.025)
        nearby = (abs(frequencies - frequency) > max(6.0, frequency * 0.045)) & (abs(frequencies - frequency) < max(22.0, frequency * 0.15))
        if not band.any():
            continue
        peak = float(power[band].max())
        floor = float(np.median(power[nearby])) if nearby.any() else 0
        matches.append(peak > max(1e-13, floor * 2.5))
    return bool(matches and matches[0] and sum(matches) >= 1)


def trim_to_audible(audio, start, end, threshold):
    """Trim model-window spill using the measured envelope, never stretch it."""
    import numpy as np
    hop = 128
    left, right = max(0, round(start * RATE)), min(len(audio), round(end * RATE))
    if right <= left:
        return None
    energy = frame_rms(audio[left:right], hop=hop, length=512)
    active = np.flatnonzero(energy >= threshold)
    if not len(active):
        return None
    first = max(start, left / RATE + active[0] * hop / RATE - 0.012)
    last = min(end, left / RATE + active[-1] * hop / RATE + 0.025)
    return (first, last) if last - first >= 0.075 else None


def measured_attack(audio, start, threshold):
    """Backtrack a late voiced decision only across a visible amplitude rise."""
    import numpy as np
    left, right = max(0, start - 0.24), min(len(audio) / RATE, start + 0.04)
    hop = 64
    energy = frame_rms(audio[round(left * RATE):round(right * RATE)], hop=hop, length=256)
    if len(energy) < 4:
        return start
    before = max(1, round((start - left) * RATE / hop))
    minimum = int(np.argmin(energy[:before]))
    peak = float(np.max(energy[minimum:]))
    floor = float(energy[minimum])
    if peak <= threshold or floor > peak * 0.35:
        return start
    crossings = np.flatnonzero(energy[minimum:] >= max(threshold, floor + (peak - floor) * 0.18))
    if not len(crossings):
        return start
    return min(start, max(0, left + (minimum + int(crossings[0])) * hop / RATE - 0.004))


class PitchEvidence:
    """One bounded STFT supports source-specific note timing and dynamics."""
    def __init__(self, audio, candidates=(), retain_spectrum=False):
        import librosa
        import numpy as np
        self.hop = 128
        self.duration = len(audio) / RATE
        spectrum = librosa.stft(audio, n_fft=4096, hop_length=self.hop)
        self.spectrum = spectrum if retain_spectrum else None
        self.power = np.square(abs(spectrum))
        self.frequencies = librosa.fft_frequencies(sr=RATE, n_fft=4096)
        self.cache = {}
        self.candidates = [(float(event[0]), float(event[1]), int(event[2])) for event in candidates]

    def envelope(self, pitch):
        import numpy as np
        from scipy.ndimage import uniform_filter1d
        if pitch in self.cache:
            return self.cache[pitch]
        f0 = 440 * 2 ** ((pitch - 69) / 12)
        harmonics = []
        for index in range(1, 5):
            frequency = f0 * index
            width = max(3.0, frequency * 0.022)
            center = abs(self.frequencies - frequency) <= width
            nearby = (abs(self.frequencies - frequency) >= width * 2) & (abs(self.frequencies - frequency) < width * 5)
            if not np.any(center):
                harmonics.append(np.zeros(self.power.shape[1], np.float32))
                continue
            energy = self.power[center].sum(axis=0)
            floor = np.median(self.power[nearby], axis=0) * np.count_nonzero(center) if np.any(nearby) else 0
            harmonics.append(np.maximum(0, energy - floor))
        fundamental = np.sqrt(harmonics[0])
        combined = np.sqrt(sum(value / (index + 1) for index, value in enumerate(harmonics)))
        combined = uniform_filter1d(combined, size=3)
        self.cache[pitch] = (combined, fundamental, harmonics)
        return self.cache[pitch]

    def independent_envelope(self, pitch, start, end):
        """Prefer the candidate's F0; never let another note's F0 time it.

        A harmonic sum is useful pitch evidence, but it is not an independent
        amplitude envelope in a polyphonic stem. An upper note can occupy a
        lower candidate's second or third harmonic and otherwise retrigger it.
        """
        import numpy as np
        from scipy.ndimage import uniform_filter1d
        _, fundamental, harmonics = self.envelope(pitch)
        a = max(0, round(start * RATE / self.hop))
        b = min(len(fundamental), max(a + 1, round(end * RATE / self.hop)))
        if b <= a:
            return None
        local = float(np.quantile(fundamental[a:b], 0.75))
        reference = float(np.quantile(fundamental, 0.99))
        source = float(np.quantile(self.power[:, a:b].sum(axis=0), 0.75))
        # Direct, concentrated fundamental evidence remains authoritative even
        # when an independent upper voice is much louder in shared harmonics.
        if local > max(1e-5, reference * 0.025) and local * local > source * 0.0002:
            return uniform_filter1d(fundamental, size=3), "fundamental"

        supported = []
        for index in range(1, len(harmonics)):
            frequency = 440 * 2 ** ((pitch - 69) / 12) * (index + 1)
            explained = any(other_pitch != pitch
                and min(end, other_end) - max(start, other_start) >= min(0.08, (end - start) * 0.3)
                and abs(440 * 2 ** ((other_pitch - 69) / 12) - frequency) <= frequency * 0.025
                for other_start, other_end, other_pitch in self.candidates)
            if explained:
                continue
            values = np.sqrt(harmonics[index])
            if float(np.quantile(values[a:b], 0.75)) ** 2 > source * 0.0002:
                supported.append((values, index + 1))
        # A missing fundamental needs at least two unexplained, agreeing
        # partials. One upper note is insufficient evidence for a submultiple.
        if len(supported) < 2:
            return None
        agreement = []
        for first in range(len(supported)):
            for second in range(first + 1, len(supported)):
                x, y = supported[first][0][a:b], supported[second][0][a:b]
                sx, sy = float(np.std(x)), float(np.std(y))
                flat = sx / max(float(np.mean(x)), 1e-9) < 0.04 and sy / max(float(np.mean(y)), 1e-9) < 0.04
                correlated = sx > 1e-9 and sy > 1e-9 and float(np.corrcoef(x, y)[0, 1]) >= 0.85
                if flat or correlated:
                    agreement = [supported[first], supported[second]]
                    break
            if agreement:
                break
        if not agreement:
            return None
        envelope = np.sqrt(sum(values * values / harmonic for values, harmonic in agreement))
        return uniform_filter1d(envelope, size=3), "harmonic-consensus"

    def refine(self, start, end, pitch):
        import numpy as np
        _, fundamental, harmonics = self.envelope(pitch)
        independent = self.independent_envelope(pitch, start, end)
        if independent is None:
            return None
        envelope, basis = independent
        a = max(0, round(start * RATE / self.hop))
        b = min(len(envelope) - 1, max(a + 1, round(end * RATE / self.hop)))
        if b <= a:
            return None
        level = float(np.quantile(envelope[a:b + 1], 0.75))
        reference = float(np.quantile(envelope, 0.99))
        # A persistent tone is musical evidence, not the noise floor. Nearby
        # off-pitch bins were already subtracted while building the envelope.
        floor = min(float(np.quantile(envelope, 0.2)), reference * 0.02)
        if level <= max(1e-5, floor * 1.7, reference * 0.025):
            return None
        # An isolated pitch envelope, rather than the entire mixed stem,
        # identifies when this note starts and stops under simultaneous voices.
        left = max(0, a - round(0.22 * RATE / self.hop))
        right = min(len(envelope), b + round(0.2 * RATE / self.hop) + 1)
        peak = float(np.quantile(envelope[a:b + 1], 0.9))
        onset_region = envelope[left:min(right, a + round(0.15 * RATE / self.hop) + 1)]
        minimum = int(np.argmin(onset_region[:max(1, a - left + 1)]))
        onset = a
        if float(onset_region[minimum]) < peak * 0.4:
            above = np.flatnonzero(onset_region[minimum:] >= max(peak * 0.48, floor * 1.7))
            if len(above):
                onset = left + minimum + int(above[0])
        ending = b
        # Permit a natural measured release, but do not consume a following
        # attack or extend to the end of another simultaneous instrument.
        threshold = max(peak * 0.13, floor * 1.7)
        # The first amplitude valley is not a note-off. Chorus/filter motion
        # can briefly suppress the fundamental in a genuinely held source note.
        # Follow the last supported release in the bounded model interval;
        # subsequent independently measured attacks trim overlaps downstream.
        active = np.flatnonzero(envelope[onset:right] >= threshold)
        if len(active):
            ending = onset + int(active[-1]) + 1
        refined_start = max(0.0, onset * self.hop / RATE)
        refined_end = min(self.duration, ending * self.hop / RATE)
        if refined_end - refined_start < 0.065:
            return None
        active = slice(onset, max(onset + 1, ending))
        energies = [float(np.mean(value[active])) for value in harmonics]
        total = sum(energies)
        brightness = sum((index + 1) * value for index, value in enumerate(energies)) / max(total, 1e-12)
        midpoint = onset + max(1, (ending - onset) // 3)
        early = float(np.mean(envelope[onset:midpoint]))
        late = float(np.mean(envelope[max(midpoint, ending - max(1, (ending - onset) // 3)):max(midpoint + 1, ending)]))
        rise = envelope[onset:min(ending, onset + round(0.4 * RATE / self.hop))]
        reached = np.flatnonzero(rise >= peak * 0.85)
        # Subtract the known analysis-window rise before suggesting a synth
        # attack; model-onset latency is not the source instrument's envelope.
        attack = max(0.003, (int(reached[0]) * self.hop / RATE - 0.04)) if len(reached) else 0.01
        before = envelope[max(0, onset - 5):max(1, onset)]
        after = envelope[onset:min(len(envelope), onset + 5)]
        previous_level = float(np.mean(before)) if len(before) else 0
        next_level = float(np.mean(after)) if len(after) else 0
        has_attack = onset <= 2 or (next_level > previous_level * 1.35 and next_level - previous_level > peak * 0.12)
        return {"start": refined_start, "end": refined_end, "loudness": level, "basis": basis, "hasAttack": has_attack,
                "brightness": brightness, "sustain": min(2.0, late / max(early, 1e-9)),
                "attack": attack}


def harmonic_duplicates(notes, evidence, offset):
    """Challenge weak, synchronous upper harmonics without banning octaves."""
    import numpy as np
    retained = []
    rejected = 0
    for note in sorted(notes, key=lambda n: (n["startSeconds"], n["pitch"])):
        duplicate = False
        for lower in retained:
            interval = note["pitch"] - lower["pitch"]
            if interval not in (12, 19, 24, 28) or abs(note["_modelStart"] - lower["_modelStart"]) > 0.035:
                continue
            if note["strength"] > lower["strength"] * 0.72 or note["durationSeconds"] > lower["durationSeconds"] * 1.25:
                continue
            left = max(note["startSeconds"], lower["startSeconds"]) - offset
            right = min(note["startSeconds"] + note["durationSeconds"], lower["startSeconds"] + lower["durationSeconds"]) - offset
            a, b = round(left * RATE / evidence.hop), round(right * RATE / evidence.hop)
            if b - a < 8:
                continue
            high = evidence.envelope(note["pitch"])[1][a:b]
            low = evidence.envelope(lower["pitch"])[1][a:b]
            flat = np.std(high) / max(np.mean(high), 1e-9) < 0.03 and np.std(low) / max(np.mean(low), 1e-9) < 0.03
            correlated = np.std(high) > 1e-9 and np.std(low) > 1e-9 and np.corrcoef(high, low)[0, 1] >= 0.98
            if flat or correlated:
                duplicate = True
                break
        if duplicate:
            rejected += 1
        else:
            retained.append(note)
    return retained, rejected


def accompaniment(audio, model, output, offset, mixture_level, emit):
    import numpy as np
    import soundfile as sf
    from basic_pitch.inference import predict
    threshold, active = audible_threshold(audio, mixture_level)
    if active < max(0.0003, mixture_level * 0.006):
        return [], 0
    proposals, accepted = 0, []
    # Bounded model windows retain context but publish each onset only once.
    step, context = 24.0, 1.0
    duration = len(audio) / RATE
    for start in np.arange(0, duration, step):
        end = min(duration, float(start) + step)
        window_start, window_end = max(0, float(start) - context), min(duration, end + context)
        window = audio[round(window_start * RATE):round(window_end * RATE)]
        if float(np.quantile(frame_rms(audio[round(start * RATE):round(end * RATE)]), 0.95)) < threshold:
            continue
        temporary = output / "model-input.wav"
        try:
            sf.write(str(temporary), window, RATE, subtype="FLOAT")
            emit(status="Extracting accompaniment locally · %d%%" % round(start / max(duration, 1e-9) * 100))
            _, _, events = predict(temporary, model_or_model_path=model, onset_threshold=0.55,
                frame_threshold=0.35, minimum_note_length=80, minimum_frequency=65.4,
                maximum_frequency=2500, multiple_pitch_bends=False, melodia_trick=False)
        finally:
            temporary.unlink(missing_ok=True)
        evidence = PitchEvidence(window, events)
        window_notes = []
        for note_start, note_end, pitch, strength, _ in events:
            a, b = window_start + float(note_start), min(duration, window_start + float(note_end))
            continuation = a < start and b > start + 0.065
            if not (start <= a < end or continuation):
                continue
            proposals += 1
            if note_level(audio, a, b) < threshold:
                continue
            refined = evidence.refine(float(note_start), float(note_end), int(pitch))
            if refined is None:
                continue
            a, b = window_start + refined["start"], min(duration, window_start + refined["end"])
            if continuation:
                a = max(a, float(start))
            if b - a < 0.065:
                continue
            window_notes.append({"pitch": int(pitch), "startSeconds": offset + a,
                "durationSeconds": b - a, "velocity": 1, "strength": float(strength),
                "_modelStart": offset + window_start + float(note_start),
                "_continuation": continuation,
                "_evidenceBasis": refined["basis"],
                "_hasAttack": refined["hasAttack"],
                "_loudness": refined["loudness"], "_brightness": refined["brightness"],
                "_sustain": refined["sustain"], "_attack": refined["attack"]})
        checked, _ = harmonic_duplicates(window_notes, evidence, offset + window_start)
        accepted.extend(checked)
    # A mixed stem is not a solo instrument. Retain real simultaneous harmony,
    # but remove duplicate detections and weakest excess voices at each attack.
    accepted.sort(key=lambda n: (n["startSeconds"], -n["strength"], n["pitch"]))
    notes = []
    for note in accepted:
        same = [n for n in notes if n["pitch"] == note["pitch"] and n["startSeconds"] + n["durationSeconds"] >= note["startSeconds"] - 0.04]
        if same:
            previous = same[-1]
            if note["_continuation"] or not note["_hasAttack"]:
                previous["durationSeconds"] = max(previous["durationSeconds"], note["startSeconds"] + note["durationSeconds"] - previous["startSeconds"])
                previous["_loudness"] = max(previous["_loudness"], note["_loudness"])
                continue
            previous["durationSeconds"] = min(previous["durationSeconds"], note["startSeconds"] - previous["startSeconds"])
        if sum(n["startSeconds"] + n["durationSeconds"] > note["startSeconds"] + 0.01 for n in notes) >= 6:
            continue
        notes.append(note)
    notes = [n for n in notes if n["durationSeconds"] >= 0.075]
    levels = [note["_loudness"] for note in notes]
    reference = float(np.quantile(levels, 0.9)) if levels else 1
    for note in notes:
        note["velocity"] = measured_velocity(note["_loudness"], reference)
    return notes, proposals


def vocal_leakage(evidence, vocals, start, end, pitch):
    """Veto weak copies coherent with the aligned vocal stem.

    A matching MIDI pitch alone never excludes an instrument: singers and
    instruments can share notes. Require vocal dominance AND matching complex
    spectral evidence, with envelope agreement or multiple agreeing partials.
    The test is deliberately conservative around ambiguous unison material.
    """
    import numpy as np
    a = max(0, round(start * RATE / evidence.hop))
    b = min(evidence.power.shape[1], vocals.power.shape[1], round(end * RATE / evidence.hop))
    if b - a < 8:
        return False
    _, source_f0, _ = evidence.envelope(pitch)
    _, vocal_f0, _ = vocals.envelope(pitch)
    source, voice = source_f0[a:b], vocal_f0[a:b]
    source_energy, voice_energy = float(np.sum(source * source)), float(np.sum(voice * voice))
    if voice_energy <= max(1e-8, source_energy * 6.25):
        return False
    correlation = float(np.corrcoef(source, voice)[0, 1]) if min(float(np.std(source)), float(np.std(voice))) > 1e-8 else 0
    f0 = 440 * 2 ** ((pitch - 69) / 12)
    coherence, dominated = [], []
    for harmonic in (1, 2, 3, 4):
        frequency = f0 * harmonic
        bins = abs(evidence.frequencies - frequency) <= max(3.0, frequency * 0.022)
        x, y = evidence.spectrum[bins, a:b], vocals.spectrum[bins, a:b]
        energy_x, energy_y = float(np.sum(abs(x) ** 2)), float(np.sum(abs(y) ** 2))
        coherence.append(float(abs(np.sum(x * np.conj(y))) ** 2 / max(energy_x * energy_y, 1e-12)))
        dominated.append(energy_y > energy_x * 4 and energy_y > voice_energy * 0.01)
    if coherence[0] >= 0.96:
        return True
    if coherence[0] >= 0.78 and correlation >= 0.78:
        return True
    return coherence[0] >= 0.7 and sum(c >= 0.7 and d for c, d in zip(coherence, dominated)) >= 2


def filter_vocal_bleed(notes, audio, vocal_audio, offset=0):
    """Keep note identities/timing; remove only supported vocal-leak copies.

    STFT memory is bounded to 24-second onset buckets plus the longest note
    in that bucket. No vocal notes are extracted or added by this operation.
    """
    if not notes or vocal_audio is None:
        return notes, 0
    duration = min(len(audio), len(vocal_audio)) / RATE
    retained, rejected = [], 0
    for block_start in range(0, math.ceil(duration), 24):
        selected = [n for n in notes if block_start <= n["startSeconds"] - offset < block_start + 24]
        if not selected:
            continue
        left = max(0, block_start - 0.2)
        right = min(duration, max(n["startSeconds"] + n["durationSeconds"] - offset for n in selected) + 0.2)
        if right - left > 48:
            # Extremely long holds are independent persistent evidence; do
            # not allocate an unbounded spectral comparison to challenge them.
            retained.extend(selected)
            continue
        evidence = PitchEvidence(audio[round(left * RATE):round(right * RATE)], retain_spectrum=True)
        vocals = PitchEvidence(vocal_audio[round(left * RATE):round(right * RATE)], retain_spectrum=True)
        for note in selected:
            start = note["startSeconds"] - offset - left
            if vocal_leakage(evidence, vocals, start, start + note["durationSeconds"], note["pitch"]):
                rejected += 1
            else:
                retained.append(note)
    return sorted(retained, key=lambda n: (n["startSeconds"], n["pitch"])), rejected


def filter_bass_harmonics(notes, audio, bass_audio, bass_events, offset=0):
    """Reject coherent bass-partial copies, not ordinary harmonic intervals.

    A source can deliberately double the bass in another register. Measured
    bass coverage alone is therefore insufficient: a candidate must also be
    much weaker and spectrally coherent with the same bass partial before it
    can be removed by the shared negative-evidence check.
    """
    if bass_audio is None or not bass_events:
        return notes, 0
    eligible, other = [], []
    for note in notes:
        start, end = note["startSeconds"], note["startSeconds"] + note["durationSeconds"]
        covered = 0
        for bass in bass_events:
            ratio = 2 ** ((note["pitch"] - bass["pitch"]) / 12)
            harmonic = round(ratio)
            if not 2 <= harmonic <= 12 or abs(ratio - harmonic) / harmonic > 0.02:
                continue
            covered += max(0, min(end, bass["startSeconds"] + bass["durationSeconds"]) - max(start, bass["startSeconds"]))
        (eligible if covered >= note["durationSeconds"] * 0.6 else other).append(note)
    retained, rejected = filter_vocal_bleed(eligible, audio, bass_audio, offset)
    return sorted(retained + other, key=lambda n: (n["startSeconds"], n["pitch"])), rejected


def overlap_fraction(lower, upper):
    """Independent simultaneous lines support separate voices; range alone does not."""
    from bisect import bisect_right
    coverage = []
    for note in sorted(lower, key=lambda n: n["startSeconds"]):
        a, b = note["startSeconds"], note["startSeconds"] + note["durationSeconds"]
        if coverage and a <= coverage[-1][1]:
            coverage[-1] = (coverage[-1][0], max(b, coverage[-1][1]))
        else:
            coverage.append((a, b))
    starts = [a for a, _ in coverage]
    count = 0
    for note in upper:
        a, b = note["startSeconds"], note["startSeconds"] + note["durationSeconds"]
        required = min(0.06, note["durationSeconds"] * 0.3)
        index = bisect_right(starts, b - required) - 1
        if index >= 0 and min(b, coverage[index][1]) - max(a, coverage[index][0]) >= required:
            count += 1
    return count / max(1, len(upper))


def partition_accompaniment(notes):
    """Partition measured notes exactly once, using register, overlap and articulation.

    These are musical voices, not identification of the recorded instruments.
    A melody that simply moves across registers remains one voice.
    """
    import numpy as np
    if not notes:
        return []
    groups = [list(notes)]
    # Sustained simultaneous notes need a separate envelope from struck motifs.
    held = [n for n in notes if n["durationSeconds"] >= 1.25 and n.get("_sustain", 1) >= 0.25]
    struck = [n for n in notes if n not in held]
    if held and struck and (len(held) >= 3 or any(n["durationSeconds"] >= 4 for n in held)):
        groups = [struck, held] if struck else [held]
    while len(groups) < 6:
        best = None
        for group_index, group in enumerate(groups):
            pitches = sorted(set(n["pitch"] for n in group))
            minimum = max(4, round(len(group) * 0.08))
            for low_pitch, high_pitch in zip(pitches, pitches[1:]):
                lower = [n for n in group if n["pitch"] <= low_pitch]
                upper = [n for n in group if n["pitch"] >= high_pitch]
                if min(len(lower), len(upper)) < minimum:
                    continue
                overlap = min(overlap_fraction(lower, upper), overlap_fraction(upper, lower))
                if overlap < 0.2:
                    continue
                register = abs(float(np.median([n["pitch"] for n in lower])) - float(np.median([n["pitch"] for n in upper])))
                if register < 6:
                    continue
                # Register separation, independent overlaps and different source
                # articulation justify multiple sound assignments.
                articulation = abs(float(np.median([n["durationSeconds"] for n in lower])) - float(np.median([n["durationSeconds"] for n in upper])))
                brightness = abs(float(np.median([n.get("_brightness", 1) for n in lower])) - float(np.median([n.get("_brightness", 1) for n in upper])))
                score = overlap * (register / 12 + min(1, articulation) + min(1, brightness))
                if score < 0.28:
                    continue
                if best is None or score > best[0]:
                    best = (score, group_index, lower, upper)
        if best is None:
            break
        _, index, lower, upper = best
        groups[index:index + 1] = [lower, upper]
    groups = sorted((group for group in groups if group), key=lambda group: (np.median([n["pitch"] for n in group]), np.median([n["durationSeconds"] for n in group])))
    result = []
    for index, group in enumerate(groups):
        group.sort(key=lambda n: (n["startSeconds"], n["pitch"]))
        median_pitch = float(np.median([n["pitch"] for n in group]))
        typical = float(np.median([n["durationSeconds"] for n in group]))
        register = "lower" if median_pitch < 60 else "middle" if median_pitch < 72 else "upper"
        articulation = "sustained" if typical >= 1.25 else "rhythmic" if typical < 0.5 else "melodic"
        result.append(("other_voice_%d" % (index + 1), "Measured %s %s voice %d" % (register, articulation, index + 1), group))
    return result


def _bass_window(audio, offset, mixture_level, emit):
    """Monophonic measured fundamentals avoid transcribing 808 harmonics as chords."""
    import librosa
    import numpy as np
    from scipy.ndimage import median_filter
    threshold, active = audible_threshold(audio, mixture_level)
    if active < max(0.0003, mixture_level * 0.006):
        return []
    rate, hop, length = 11025, 128, 2048
    values = librosa.resample(audio, orig_sr=RATE, target_sr=rate)
    emit(status="Measuring bass fundamentals locally…")
    f0, voiced, probability = librosa.pyin(values, fmin=27.5, fmax=220, sr=rate,
        frame_length=length, hop_length=hop, fill_na=np.nan, n_thresholds=40,
        max_transition_rate=12, resolution=0.1)
    energy = librosa.feature.rms(y=values, frame_length=length, hop_length=hop)[0]
    usable = np.isfinite(f0) & voiced & (probability >= 0.18) & (energy >= threshold)
    pitches = np.zeros(len(f0), dtype=np.int16)
    pitches[usable] = np.rint(librosa.hz_to_midi(f0[usable])).astype(np.int16)
    pitches = median_filter(pitches, size=3)
    pitches[~usable] = 0
    # Attack evidence splits repeated notes on the same pitch, without a grid.
    onset = librosa.onset.onset_strength(y=values, sr=rate, hop_length=hop)
    attacks = set(librosa.onset.onset_detect(onset_envelope=onset, sr=rate, hop_length=hop,
        backtrack=False, pre_max=3, post_max=3, pre_avg=5, post_avg=5, delta=0.12, wait=5))
    notes = []
    begin, current = 0, 0
    duration = len(audio) / RATE
    for index in range(len(pitches) + 1):
        pitch = int(pitches[index]) if index < len(pitches) else 0
        split = index in attacks and index - begin >= round(0.12 * rate / hop)
        if pitch == current and not split:
            continue
        if current:
            start = max(0, begin * hop / rate - 0.025)
            end = min(duration, index * hop / rate - 0.025)
            if end - start >= 0.09:
                trimmed = trim_to_audible(audio, start, end, threshold)
                if trimmed is not None and pitch_present(audio, trimmed[0], trimmed[1], current):
                    a, b = trimmed
                    notes.append({"pitch": current, "startSeconds": offset + a,
                                  "durationSeconds": b - a, "velocity": 1})
        begin, current = index, pitch
    # A brief one-semitone decay into a stable fundamental is an observed 808
    # attack glide, not another struck note. The renderer cannot express bends;
    # anchor that attack to its measured stable pitch rather than retriggering.
    collapsed = []
    index = 0
    while index < len(notes):
        note = notes[index]
        if index + 1 < len(notes):
            following = notes[index + 1]
            gap = following["startSeconds"] - note["startSeconds"] - note["durationSeconds"]
            boundary = round((following["startSeconds"] - offset + 0.025) * rate / hop)
            local_f0 = f0[max(0, boundary - 6):min(len(f0), boundary + 6)]
            local_f0 = local_f0[np.isfinite(local_f0)]
            local_midi = librosa.hz_to_midi(local_f0) if len(local_f0) else np.array([])
            smooth_slide = len(np.unique(np.round(local_midi, 1))) >= 4 and len(local_midi) > 3 and np.max(abs(np.diff(local_midi))) < 0.65
            near_attack = any(abs(attack - boundary) <= 3 for attack in attacks)
            if note["durationSeconds"] <= 0.3 and following["durationSeconds"] >= note["durationSeconds"] * 1.5 and note["pitch"] == following["pitch"] + 1 and abs(gap) < 0.025 and smooth_slide and not near_attack:
                note = dict(note, pitch=following["pitch"], durationSeconds=following["startSeconds"] + following["durationSeconds"] - note["startSeconds"])
                index += 1
        collapsed.append(note)
        index += 1
    # Joining tiny detector gaps does not change measured pitch or attack order.
    merged = []
    for note in collapsed:
        if merged and merged[-1]["pitch"] == note["pitch"] and note["startSeconds"] - (merged[-1]["startSeconds"] + merged[-1]["durationSeconds"]) < 0.04:
            previous = merged[-1]
            previous["durationSeconds"] = note["startSeconds"] + note["durationSeconds"] - previous["startSeconds"]
        else:
            merged.append(note)
    attack_times = np.asarray(sorted(attacks)) * hop / rate
    for index, note in enumerate(merged):
        local_start = note["startSeconds"] - offset
        energy_attack = measured_attack(audio, local_start, threshold)
        preceding = attack_times[(attack_times >= local_start - 0.22) & (attack_times <= local_start)]
        if len(preceding) or energy_attack < local_start:
            candidate = energy_attack if energy_attack < local_start else max(0, float(preceding[-1]) - 0.012)
            # Onset strength supplies measured attack evidence for pYIN's late
            # voiced decision. Never move into the preceding note's sustain.
            minimum = (merged[index - 1]["startSeconds"] + merged[index - 1]["durationSeconds"] - offset) if index else 0
            previous_start = merged[index - 1]["startSeconds"] - offset if index else 0
            if candidate < minimum and index and candidate > previous_start + 0.09:
                merged[index - 1]["durationSeconds"] = candidate - previous_start
                minimum = candidate
            if candidate >= minimum and note_level(audio, candidate, min(local_start + 0.1, len(audio) / RATE)) >= threshold:
                old_end = note["startSeconds"] + note["durationSeconds"]
                note["startSeconds"] = offset + candidate
                note["durationSeconds"] = old_end - note["startSeconds"]
    return assign_velocities(merged, audio, offset)


def bass_notes(audio, offset, mixture_level, emit):
    """Limit pYIN's state matrix to a bounded analysis window."""
    duration = len(audio) / RATE
    if duration <= 30:
        return _bass_window(audio, offset, mixture_level, emit)
    notes = []
    for start in range(0, math.ceil(duration), 24):
        end = min(duration, start + 24)
        left, right = max(0, start - 1), min(duration, end + 1)
        values = audio[round(left * RATE):round(right * RATE)]
        for note in _bass_window(values, offset + left, mixture_level, emit):
            a = max(offset + start, note["startSeconds"])
            b = min(offset + end, note["startSeconds"] + note["durationSeconds"])
            if b - a < 0.025:
                continue
            note = dict(note, startSeconds=a, durationSeconds=b - a)
            if notes and notes[-1]["pitch"] == note["pitch"] and abs(notes[-1]["startSeconds"] + notes[-1]["durationSeconds"] - a) < 0.002 and abs(a - (offset + start)) < 0.002:
                notes[-1]["durationSeconds"] = b - notes[-1]["startSeconds"]
            else:
                notes.append(note)
    return assign_velocities(notes, audio, offset)


def _drum_window(audio, offset, mixture_level):
    import librosa
    import numpy as np
    from scipy.signal import find_peaks
    hop, size = 110, 1024
    threshold, active = audible_threshold(audio, mixture_level)
    if active < max(0.0003, mixture_level * 0.008):
        return [], None, 0
    spectrum = abs(librosa.stft(audio, n_fft=size, hop_length=hop)) ** 2
    frequencies = librosa.fft_frequencies(sr=RATE, n_fft=size)
    ranges = [(36, 35, 180), (38, 250, 4500), (42, 6000, 10500)]
    energies = {pitch: np.sqrt(spectrum[(frequencies >= low) & (frequencies < high)].sum(axis=0) / size) for pitch, low, high in ranges}
    full = frame_rms(audio, hop=hop, length=size)
    notes = []
    for pitch, low, high in ranges:
        energy = energies[pitch]
        smooth = np.convolve(energy, np.ones(3) / 3, mode="same")
        novelty = np.maximum(0, smooth - np.roll(smooth, 4))
        novelty[:4] = 0
        reference = float(np.quantile(novelty[novelty > 0], 0.9)) if np.any(novelty > 0) else 0
        if reference < 1e-6:
            continue
        peaks, _ = find_peaks(novelty, distance=round(0.045 * RATE / hop),
                              height=reference * 0.17, prominence=reference * 0.12)
        strengths = []
        candidates = []
        for index in peaks:
            time = index * hop / RATE
            if time >= len(audio) / RATE or full[index] < threshold:
                continue
            low_e, mid_e, high_e = (energies[p][index] for p in (36, 38, 42))
            if pitch == 36 and low_e < max(mid_e * 0.5, high_e * 0.8):
                continue
            # A kick's broadband click is not an additional snare. A snare
            # candidate must have clearly dominant mid-band attack energy.
            if pitch == 38 and (mid_e < low_e * 3.0 or mid_e < high_e * 0.75):
                continue
            if pitch == 42 and high_e < max(low_e * 0.06, mid_e * 0.09):
                continue
            # Find the beginning of the measured rise, up to 30 ms earlier.
            first = max(0, index - 6)
            minimum = first + int(np.argmin(smooth[first:index + 1]))
            start = max(0, minimum * hop / RATE)
            if candidates and start - candidates[-1]["startSeconds"] + offset < 0.045:
                continue
            tail = 0.1 if pitch == 42 else 0.14
            end = min(len(audio) / RATE, start + tail)
            if end <= start:
                continue
            candidates.append({"pitch": pitch, "startSeconds": offset + start,
                               "durationSeconds": end - start, "velocity": 1,
                               "_loudness": float(energy[index])})
            strengths.append(float(novelty[index]))
        if pitch == 36:
            filtered, filtered_strengths = [], []
            for note, strength in zip(candidates, strengths):
                if filtered and note["startSeconds"] - filtered[-1]["startSeconds"] < 0.15 and strength < filtered_strengths[-1] * 0.65:
                    continue
                filtered.append(note)
                filtered_strengths.append(strength)
            candidates, strengths = filtered, filtered_strengths
        notes.extend(candidates)
    notes.sort(key=lambda n: (n["startSeconds"], n["pitch"]))
    assign_drum_velocities(notes)
    envelope = librosa.onset.onset_strength(y=audio, sr=RATE, hop_length=256)
    tempo = None
    quality = 0.0
    if len(notes) >= 4 and np.any(envelope > 0):
        estimated, beats = librosa.beat.beat_track(onset_envelope=envelope, sr=RATE, hop_length=256, trim=False)
        value = float(np.asarray(estimated).reshape(-1)[0])
        intervals = np.diff(beats) * 256 / RATE
        if len(intervals) >= 3 and 35 <= value <= 240:
            tempo = value
            quality = float(np.clip(1 - np.std(intervals) / max(np.mean(intervals), 1e-6), 0, 1))
    return notes, tempo, quality


def drum_notes(audio, offset, mixture_level):
    """Keep spectral-flux allocations independent of the full song length."""
    import numpy as np
    duration = len(audio) / RATE
    if duration <= 30:
        return _drum_window(audio, offset, mixture_level)
    notes, tempos, qualities = [], [], []
    for start in range(0, math.ceil(duration), 24):
        end = min(duration, start + 24)
        left, right = max(0, start - 0.2), min(duration, end + 0.2)
        found, tempo, quality = _drum_window(audio[round(left * RATE):round(right * RATE)], offset + left, mixture_level)
        notes.extend(n for n in found if offset + start <= n["startSeconds"] < offset + end)
        if tempo is not None:
            tempos.append(tempo)
            qualities.append(quality)
    notes.sort(key=lambda n: (n["startSeconds"], n["pitch"]))
    # One class-wide amplitude reference, not a new normalization per worker
    # window. A quiet section must stay quiet relative to a louder section.
    assign_drum_velocities(notes)
    # Half/double-time estimates must never be averaged into an unrelated BPM.
    best = int(np.argmax(qualities)) if qualities else None
    return notes, tempos[best] if best is not None else None, qualities[best] if best is not None else 0.0


def assign_drum_velocities(notes):
    import numpy as np
    for pitch in sorted({n["pitch"] for n in notes}):
        selected = [n for n in notes if n["pitch"] == pitch]
        reference = float(np.quantile([n["_loudness"] for n in selected], 0.9))
        for note in selected:
            note["velocity"] = measured_velocity(note["_loudness"], reference, nominal=108)


def sound_parameters(role, audio, notes):
    import librosa
    import numpy as np
    if role == "drums":
        pitches = {note["pitch"] for note in notes}
        cutoff = 1800.0 if pitches <= {36} else 16000.0 if pitches <= {38} else 20000.0
        decay = 0.24 if pitches <= {36} else 0.14 if pitches <= {38} else 0.07
        return {"attack": 0.001, "decay": decay, "sustain": 0.0, "release": 0.05,
                "cutoff": cutoff, "lfoDepth": 0.0, "detune": 0.0,
                "reverb": 0.02, "drive": 0.0, "delay": 0.0}
    # A bounded, distributed sample keeps timbre inspection small on long songs.
    if len(audio) > 30 * RATE:
        starts = np.linspace(0, len(audio) - 5 * RATE, 6, dtype=int)
        audio = np.concatenate([audio[first:first + 5 * RATE] for first in starts])
    spectrum = abs(librosa.stft(audio, n_fft=2048, hop_length=512))
    centroids = librosa.feature.spectral_centroid(S=spectrum, sr=RATE)[0]
    energy = np.sqrt(np.mean(spectrum * spectrum, axis=0))
    active = centroids[energy > max(1e-6, float(np.quantile(energy, 0.95)) * 0.03)]
    centroid = float(np.median(active)) if len(active) else 500
    durations = [n["durationSeconds"] for n in notes]
    typical = float(np.median(durations)) if durations else 0.3
    if role == "bass":
        return {"oscillator": 0.0 if centroid < 300 else 3.0, "attack": 0.003,
                "decay": min(1.2, max(0.1, typical * 0.5)), "sustain": 0.78,
                "release": 0.08, "cutoff": min(1800.0, max(180.0, centroid * 4)),
                "resonance": 0.05, "lfoDepth": 0.0, "detune": 0.0,
                "drive": min(0.2, max(0.0, (centroid - 130) / 1500)),
                "reverb": 0.0, "delay": 0.0}
    measured = [n for n in notes if "_brightness" in n]
    if measured:
        brightness = float(np.median([n["_brightness"] for n in measured]))
        fundamental = 440 * 2 ** ((float(np.median([n["pitch"] for n in measured])) - 69) / 12)
        attack = float(np.clip(np.median([n["_attack"] for n in measured]), 0.003, 0.3))
        sustain = float(np.clip(np.median([n["_sustain"] for n in measured]) * 0.7, 0.04, 0.85))
        cutoff = min(7000.0, max(450.0, fundamental * brightness * 5))
        waveform = 0.0 if brightness < 1.2 else 3.0
    else:
        attack, sustain, cutoff, waveform = (0.14 if typical >= 1.5 else 0.008), (0.24 if typical < 0.5 else 0.6), min(7000.0, max(600.0, centroid * 3)), 3.0
    return {"oscillator": waveform, "attack": attack, "decay": min(1.2, max(0.12, typical * 0.7)),
            "sustain": sustain, "release": min(0.5, max(0.06, typical * 0.2)),
            "cutoff": cutoff, "resonance": 0.1,
            "lfoDepth": 0.0, "detune": 0.0, "drive": 0.0, "reverb": 0.1, "delay": 0.0}


def reconstruct(args, basic, emit, check_audio):
    import numpy as np
    import soundfile as sf
    from basic_pitch.inference import Model
    inputs = json.loads(Path(args.inputs).read_text())
    if not isinstance(inputs, list) or not 1 <= len(inputs) <= 4:
        raise ValueError("Choose the returned reference stems for reconstruction.")
    paths = {}
    duration = None
    for value in inputs:
        name = value.get("name")
        if name not in {"bass", "other", "drums", "vocals"} or name in paths:
            raise ValueError("The reconstruction has unknown or duplicate stems.")
        path = Path(value["path"])
        info = check_audio(path, sf)
        if duration is None:
            duration = info.duration
        if abs(info.duration - duration) > 0.025:
            raise ValueError("The separated stems do not share the same timing.")
        paths[name] = path
    start, end = args.start_seconds, args.end_seconds
    if not math.isfinite(start) or not math.isfinite(end) or not 0 <= start < end <= min(600.001, duration + 0.001):
        raise ValueError("Choose a valid source range of up to ten minutes.")
    end = min(end, duration)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    destination = output / "reconstruction.json"
    if destination.exists():
        raise ValueError("The reconstruction destination already contains output.")
    audio = {name: read_range(path, start, end) for name, path in paths.items()}
    levels = {name: rms(value) for name, value in audio.items() if name != "vocals"}
    mixture_level = math.sqrt(sum(level * level for level in levels.values()))
    warnings = ["The vocal stem is never converted into an instrument. Aligned vocal-dominance and coherent-partial checks conservatively reject vocal leakage in melodic stems; ambiguous unison material can remain. Mixed accompaniment can contain several instruments.",
                "Bass fundamentals and drum classes are local estimates. Brief measured 808 attack slides are approximated as stable holds because the synth has no pitch bends."]
    parts, tempo, quality = [], None, 0.0
    bass_events = []
    if mixture_level < 0.0002:
        warnings.append("The requested instrumental range is silent or below the audibility floor; no notes were invented.")
    else:
        for name, role, title in [("bass", "bass", "Measured bass"), ("other", "accompaniment", "Measured accompaniment"), ("drums", "drums", "Measured drums")]:
            if name not in audio:
                warnings.append("The %s stem was unavailable." % name)
                continue
            values = audio[name]
            if name == "bass":
                notes = bass_notes(values, start, mixture_level, emit)
            elif name == "other":
                emit(status="Loading Basic Pitch for accompaniment…")
                model = Model(basic)
                notes, proposals = accompaniment(values, model, output, start, mixture_level, emit)
                warnings.append("Accompaniment retained %d of %d model note proposals after source-energy and harmonic checks." % (len(notes), proposals))
            else:
                emit(status="Measuring drum attacks locally…")
                notes, tempo, quality = drum_notes(values, start, mixture_level)
                warnings.append("Kick, snare and closed-hat classes are measured band/onset estimates, not a drum transcription model.")
            if name in {"bass", "other"}:
                notes, rejected = filter_vocal_bleed(notes, values, audio.get("vocals"), start)
                if rejected:
                    warnings.append("Excluded %d %s events supported as leakage from the aligned vocal stem." % (rejected, role))
                if "vocals" not in audio:
                    warnings.append("No aligned vocal stem was available to challenge possible %s vocal leakage." % role)
            if name == "bass":
                bass_events = notes
            elif name == "other":
                notes, rejected = filter_bass_harmonics(notes, values, audio.get("bass"), bass_events, start)
                if rejected:
                    warnings.append("Excluded %d accompaniment events supported as coherent bass-partial leakage; harmonic intervals alone never exclude notes." % rejected)
            if not notes:
                warnings.append("No reliable %s events were found in the chosen source range." % role)
                continue
            if sum(len(part["notes"]) for part in parts) + len(notes) > MAX_NOTES:
                raise ValueError("The reconstruction exceeds 65,536 measured notes. Choose a shorter range.")
            groups = [(name, title, notes)]
            if name == "other":
                groups = partition_accompaniment(notes)
                warnings.append("Accompaniment is partitioned into %d measured voices by register, overlapping note lines and source articulation; these groups do not identify original instruments." % len(groups))
                warnings.append("Accompaniment timing and velocity use independent fundamental envelopes. Missing fundamentals require agreeing partials not explained by another active candidate; weak synchronous duplicates are challenged using fundamental-only evidence.")
            elif name == "drums":
                groups = [(identifier, label, [note for note in notes if note["pitch"] in pitches])
                    for identifier, label, pitches in [
                        ("drums_kick", "Measured kick", {36}),
                        ("drums_snare", "Measured snare", {38}),
                        ("drums_hat", "Measured hats", {42, 46})]]
                groups = [group for group in groups if group[2]]
                warnings.append("Kick, snare and hats use separate measured class parts with class-specific bandwidth and source-amplitude shares.")
            total_voice_energy = sum(n.get("_loudness", 1) ** 2 * n["durationSeconds"] for n in notes)
            for identifier, label, selected in groups:
                fraction = math.sqrt(sum(n.get("_loudness", 1) ** 2 * n["durationSeconds"] for n in selected) / max(total_voice_energy, 1e-12))
                parameters = sound_parameters(role, values, selected)
                clean_notes = [{key: note[key] for key in ("pitch", "startSeconds", "durationSeconds", "velocity")} for note in selected]
                parts.append({"id": identifier, "role": role, "name": label, "notes": clean_notes,
                              # This is an amplitude contribution. Its squared
                              # L2 sum recovers the stem's relative amplitude.
                              "relativeGain": min(1.0, levels[name] / max(levels.values(), default=1)) * fraction,
                              "suggestedParameters": parameters})
    if tempo is not None:
        warnings.append("Tempo quality measures beat-grid regularity only. Half/double-time ambiguity remains; measured note timing was not quantized.")
    result = {"profile": PROFILE, "sourceStartSeconds": start, "sourceEndSeconds": end,
              "tempo": tempo, "tempoQuality": quality, "parts": parts, "warnings": warnings[:16]}
    encoded = json.dumps(result, separators=(",", ":"), allow_nan=False).encode()
    if len(encoded) > min(args.maximum_bytes, 24 * 1024 * 1024):
        raise ValueError("The reconstruction exceeds its metadata storage allowance.")
    destination.write_bytes(encoded)
    emit(status="Measured reconstruction ready")
    return [{"name": "reconstruction", "file": "reconstruction.json"}]
