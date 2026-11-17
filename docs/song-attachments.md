# Song attachments

Attach songs to a chat when you want the agent to use existing music as a reference or audio source. This is separate from importing audio directly into the arrangement and from the local Transcribe performance workflow.

## Setup and use

Local Demucs separation and Basic Pitch note extraction require an **Apple silicon Mac**. The pinned processing runtime does not support Intel Macs.

1. Save your OpenAI key in Settings for chat and composition.
2. Install [uv](https://docs.astral.sh/uv/getting-started/installation/) if it is not already available. Under **Song Attachments**, click **Set Up Local Processing**. This explicitly downloads the managed Python runtime, Demucs and Basic Pitch models. Setup shows progress, supports cancellation and can be retried.
3. Click the paperclip in chat or drop MP3, M4A, WAV, or AIFF files onto chat. Use attachment actions to change their order or remove an unsent attachment.
4. Write a prompt and Send. Examples: “Replicate the instruments in the first song,” “Recreate this as closely as you can,” “Convert this song into reggae,” or “Use the second song’s vocals over the first song’s instruments, then switch to the second instrumental at its drop.”

No Mureka account or key is required. Stem separation and note extraction run on your Mac without per-song API charges. The app does not install models or runtime packages during startup or builds.

Setup finds uv in `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin`. Its own Python environment and models live in `~/Library/Application Support/Unableton/LocalProcessing`; the app does not use your shell’s Python packages.

Use **Check Setup** to refresh the installation status. If processing reports damaged model files, use **Repair Setup** to verify and repair the installation.

The numbered songs belong to that conversation. Sending freezes their order and selection context. Follow-up prompts can use earlier attachments; other chats do not automatically receive them. Pending attachments survive save/reopen. Attaching alone changes no tracks, notes, musical revision, or musical Undo.

Files are copied into project-owned storage. The originals can then be moved or deleted. Saved packages include the sources, retained measurements and MIDI, and audio used by successful edits. Credentials and the local processing runtime stay outside song documents.

## Processing

The agent requests only the work it needs. Local analysis reports source metadata, rhythm and bass-energy estimates. Demucs separates the reference into audio stems. Basic Pitch runs on requested melodic stems and converts its detected notes into MIDI; asking only for audio stems does not also run note transcription. Results are cached by source content and the local engine/model version.

Basic Pitch works best on an isolated instrument. A mixed “other” stem can still contain several instruments, and its extracted notes may be wrong or incomplete. Drum stems remain audio; the app does not silently invent drum MIDI or claim complete instrument-by-instrument reconstruction.

For a close instrumental recreation, the agent uses a separate versioned reconstruction profile. It filters quiet separator leakage, estimates monophonic bass fundamentals with local pYIN, and checks Basic Pitch accompaniment proposals against independent fundamental-frequency envelopes. Harmonic fallback requires agreeing partials that another active pitch does not explain. A higher voice must not retrigger or change the velocity of a held lower note. Overlapping registers, phrase continuity and articulation guide separate accompaniment voices; retained notes are assigned once. Kick, snare and hats have separately measured events and sound controls. Vocal-derived notes are excluded. Drum classes, bass slides and mixed accompaniment remain approximate.

The host compares production renders of compatible installed sounds across up to three passages. Source-aligned preroll keeps a held note from being compared with a fresh attack. Distinct preset patches and bounded control refinements compete on spectrum, harmonic shape and attack/hold/release behavior; drum keys use drum-class frequency bands. Independently measured neighboring pitches help separate overlapping harmonics. Level matching compares each part's fundamental or drum-class energy, rather than assigning every part the entire stem's energy. One common gain adjustment preserves their balance. The search uses verified installed-bank leases and downloads no sounds. These feature distances are not a listening judgment or identification of the original instrument. The agent can explicitly select other catalog instruments through ordinary sound preparation.

Reconstruction preserves source timing and rests. The agent explicitly names existing competing tracks to mute, so the new notes form one arrangement instead of being layered over unrelated phrases. Prior tracks remain in the song and the complete change has one Undo step. The host renders the actual candidate before accepting the reconstruction tool and rejects silent or clipped output. Unsupported pitches are not silently transposed or removed.

Raw MIDI import remains available separately. Saved reconstruction measurements include their profile and source range; old unfiltered MIDI is not reused as a cleaned reconstruction. Earlier reconstruction versions remain readable with their original clips and provenance; new reconstruction requests reanalyze with the current profile. Source metadata and per-clip provenance survive save/reopen.

Original vocals remain audio by default for recreation or style conversion. Vocal-to-instrument conversion requires an explicit request in the current prompt, such as “Convert the vocals to piano notes.” Asking to keep vocals, remix vocal audio, or recreate a song does not enable it. The host enforces this for processing, cached MIDI and insertion; a model tool argument cannot grant permission. Instrumental reconstruction also compares aligned vocal evidence to reject matching leakage while retaining independent instrument notes. Separation remains approximate, so this does not guarantee that every vocal artifact is removed. These are not voice clones or newly synthesized singing. The agent can select source ranges, combine exact stem names into one instrumental, align a constant tempo while preserving pitch, and apply equal-power clip fades. Producer exposes fade lengths in clip properties; Superhuman shows them as readouts.

Prepared audio retains its source, selected stems, gain, range and tempo settings. Playback, preview and WAV export use the same asset. Later tempo or note changes do not automatically stretch or regenerate it.

## OpenAI and cost

Chat and composition still use your existing OpenAI key and provider billing. Their context includes prompts, attachment metadata, measured notes and local analysis; it does not include source audio by default.

**Allow OpenAI audio inspection** is a separate setting, off by default. When enabled, the agent can send a targeted excerpt of up to 60 seconds to `gpt-audio-1.5` for interpretation. This uses the OpenAI key and incurs OpenAI charges. It does not replace or upgrade the selected composition model. The old cloud-song-processing preference does not enable this new permission.

Disabling audio inspection leaves local analysis, Demucs separation and Basic Pitch transcription available. Immediately before an optional audio upload, the app rechecks that inspection is still enabled. Only bounded text findings enter the composition conversation, not base64 audio.

Local processing uses disk space, memory and processing time after the one-time download. It needs no additional paid music-processing service.

## Limits and failures

- Four files per message; ten minutes and 100 MiB per source.
- 1 GiB of retained reference sources and derived audio per open project, including audio kept for Undo. Removed unsent sources are omitted from future saves; bytes owned by older saves remain until the document closes.
- 512 MiB of decoded audio in a playback graph and 768 MiB of decoded preparation allocations. These are audio allocation limits, not a total process-memory guarantee. Foundation may materialize saved file contents while writing a package.
- 4 GiB per reference-processing cache and per prompt’s temporary audio draft. Large all-stem arrangements may require shorter ranges or fewer layers. Local model inference has its own working-memory requirements.
- Constant-tempo alignment from half to twice the source speed. Variable-tempo warping and automatic key transposition are not provided.
- Up to eight optional OpenAI audio inspections per prompt, sharing the existing model request/token budget. Processing dependencies share the bounded dependency-wait allowance; upgrades and revision replans do not reset counters.

Local tempo, beat and bass-energy measurements are estimates. A rise in bass energy is not proof of a musical drop. The agent should ask for a timestamp when the intended landmark is unclear. Missing MIDI does not prevent using valid audio stems.

Audio is staged before it enters the document. Cancellation, invalid output, unavailable instruments, storage limits and repeated revision conflicts leave the live arrangement intact. Completed edits apply automatically as one Undo step. Failed local work can be retried without buying a new provider job.

## Verification

Automated checks use generated audio, MIDI and injected processing boundaries. They cover package persistence, chat scope, shared commands, timing, pitch-preserving preparation, fades, budgets, cancellation and failure behavior. See [verification notes](verification.md) for actual model runs and remaining acceptance checks.

Separation quality, extracted note accuracy, ambiguous drops and the four example prompts still need broader testing with suitable songs and human listening. Synthetic fixtures do not establish real-song accuracy.
