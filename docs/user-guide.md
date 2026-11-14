# User guide

See the [project overview](../README.md) for screenshots and a quick start.

Unableton is an open-source, AI-first music editor for macOS. Describe a song, then refine its notes, instruments, arrangement, and mix through chat or edit them directly.

Instrument parts remain editable notes and sound settings. Transcribe converts a recorded or imported solo performance into editable instrument notes or drum hits. Generated vocals, recordings and imported audio remain audio clips. Multiple chats can work on the same song, and each completed AI edit can be undone as one change.

## Build and run

Requires macOS 26 or newer, Xcode command-line tools with Swift 6.2 or newer, for development. Runtime sound downloads use the native app; the optional catalog-audit tooling also needs Python 3.

```sh
./script/build_and_run.sh
```

The run script builds the Swift package and stages `dist/Unableton.app` without downloading or bundling sampled sounds. Six procedural synth/electronic sounds work immediately offline. Download sampled instruments separately from Window → Sound Library…. Installed sounds are shared by all songs and remain available offline.

The Codex Run action uses the same script. Other supported modes are `--verify`, `--build-only`, `--debug`, `--logs`, and `--telemetry`. The local bundle is ad-hoc signed; it is not a notarized distribution release.

```sh
swift build
swift test
```

`swift build` compiles the executable and libraries. Use the run script to launch the GUI with its document registration, privacy text, icon, and catalog resources.

## View modes

**Superhuman** is the default: compose through chat and inspect the arrangement, notes, instruments, effects, audio metadata and source takes without manual music editing controls. Playback, seeking, loop on/off, Undo/Redo, saving, exporting, recording, importing and Transcribe remain available. Detected transcription notes are read-only; timing, placement and layering remain generation choices.

**Producer** keeps the full editing interface. Switch using the toolbar mode picker or View menu: Control-Command-1 for Superhuman, Control-Command-2 for Producer. Each window has its own mode, restored with that window; new windows use the last mode you explicitly chose. Switching does not change the song or interrupt playback, capture or AI generation. Pending manual field drafts are discarded when entering Superhuman.

Both modes keep the floating AI chat, pinned track information and navigable timeline. Selecting a clip opens Notes; use Inspect in Superhuman to browse Notes, Instrument and Effects. Track mute/solo/arm and mix settings appear as information rather than controls. Recording/importing still adds audio directly, and Transcribe inserts generated tracks; these are allowed creation workflows in both modes.

## Sound Library

Click **Sound Library** in the main toolbar, choose **Window → Sound Library**, or use **Choose Sound…** in the instrument editor. These all open the same library, replacing the old toolbar popup and the editor's instrument dropdown. The reviewed library offers 45 sampled instruments across 42 downloadable banks, alongside six built-in sounds. Browse the visual grid by instrument family, search names and musical roles, filter sources, or open **On This Mac** for sounds ready offline. Select a sound to see its details, license, and download size. **Downloads** keeps progress, failures, retry actions, and recent completions visible while you browse. **Library Actions** contains Import Existing Sounds and Download Entire Library; whole-library totals exclude installed and queued downloads.

Click **Preview** to hear a short example of a built-in or downloaded sound. Previews run locally, pause song playback at its current position, and never resume the song automatically. They are unavailable during recording or microphone preparation. Selecting or downloading a sound never starts audio. Arrow keys navigate the grid; Space previews the selection when the grid has focus, Escape stops a preview, and Command-F searches.

Opening the library from the toolbar or instrument editor reveals the selected instrument and names its originating song and track. In Producer, **Use** or **Download & Use** applies to that track as one undoable edit. With no track or an audio track selected, **Add Instrument Track** or **Download & Add Track** creates a separate instrument track; audio tracks stay intact. A changed selection, revision, mode, or closed document prevents a delayed assignment or creation. Superhuman supports browsing, downloads, and previews without manual assignment. Window-menu browsing never infers a new target from the focused song.

Downloads use reviewed, pinned FreePats versions, verify both archives and extracted files, and install under `~/Library/Application Support/Unableton/SoundLibrary`. Shared downloads may contain several sound choices; the inspector and removal confirmation list them. Cancel releases only the library's request when another operation still needs the download. Imports report successful files and individual failures together, leaving originals untouched. Explicit library downloads do not enable automatic AI downloads.

The app contains no sampled banks and performs no startup downloads. Bass, Lead, Pad, Pluck, Synth strings and Electronic drums are built in. Library management works in both view modes; assigning a sound manually requires Producer. Download & Use waits for installation and rechecks the selected track and mode before changing the song.

Missing sounds do not prevent opening, inspecting, saving, editing notes, Undo/Redo or MIDI export. Playback, WAV export and previews list required downloads rather than substituting instruments. Silent/Solo Transcribe capture and original takes work without sampled sounds. Ordinary recording offers recording without accompaniment when song sounds are missing.

The first AI-required download asks to enable automatic sound downloads. Change this in Settings → Sound Library. Generation pauses its five-minute active-work clock only during consent and installation, with at most 30 minutes of total dependency waiting; all request, token and retry limits remain shared across upgrades and replans. Canceled or failed music generation keeps completed library downloads but leaves the song intact.

**Import Existing Sounds…** accepts only exact SF2 versions in the catalog, verifies their hashes, and leaves originals untouched. Existing development caches and old app banks are never loaded implicitly. Remove Download frees a bank when no playback, rendering or generation holds it; songs may then need another download.

Some FreePats SF2 banks fail native sampler checks and are excluded; exact evidence is in [the catalog audit](sound-library-audit.json). The original acoustic drum identity is retained for old songs, but some mapped notes render silently in Apple's sampler. Those notes remain saved and exportable as MIDI; playback reports the limitation instead of silently omitting them. Use Electronic drums for a complete GM-style kit.

## AI setup

Open Unableton → Settings, enter an OpenAI API key, and click Save Key. Credentials use a local file by default in every build. Settings → Credentials → Use macOS Keychain for Credentials is off by default; enable it to save and load keys through Keychain instead. Test Connection verifies the selected model's Responses function-call support.

All providers use the selected store. The local file is unencrypted at `~/Library/Application Support/Unableton/Credentials/credentials.json`, with owner-only directory/file permissions (`0700`/`0600`), outside Git, app bundles and song documents. An existing development credentials file is kept in place; Settings displays the active path. Missing local keys never trigger a Keychain fallback, and the old development preference does not enable Keychain. Switching the toggle does not move existing keys: save keys in the selected store. When Keychain is enabled, use Load Saved Key to read an existing key explicitly; opening Settings does not read it automatically.

The model dropdown includes:

- **Automatic:** start with GPT-6 Luna. If the model requests more capability or cannot complete valid edits within its economical attempt, restart once with GPT-6 Astra. The unsuccessful draft is discarded and the upgrade is shown in the chat.
- **Fixed models:** use Luna, Sol, Astra, or another compatible model without automatic upgrades.
- **Other:** enter a model ID explicitly. Refresh Models discovers supported choices available to the account.

Automatic upgrades can cost substantially more than the economical attempt. Select a fixed model to keep every request on that model. Model availability and prices are controlled by OpenAI; see the [model catalog](https://developers.openai.com/api/docs/models) and [pricing](https://developers.openai.com/api/docs/pricing).

Generation uses the Responses API with strict project tools. Prompts, musical notes, instrument settings, and relevant conversation context go to OpenAI. Audio stays on the Mac unless a vocal provider is enabled; local previews report numerical measurements. This version does not send recordings to an audio-understanding model.

Each prompt shares one five-minute deadline, at most 32 model requests, 65,536 output tokens, and two transient retries across composition steps, model upgrades and the single allowed revision replan. Usage includes discarded attempts. After an automatic upgrade, a revision replan keeps the stronger model. Optional Transcribe arrangement uses the same limits; faithful transcription stays offline.

## Draft analysis and Jev observation

After an AI edit is applied, Unableton analyzes the before/after snapshots locally. Expand **Draft analysis** beneath the assistant's message to inspect changed tracks and clips, note/drum counts, pitch statistics, generated-vocal clip coverage, repeated note patterns and uniform timeline activity windows. Copy Analysis copies the full report. The report remains attached to that generation after Undo and save/reopen; old projects open without reports.

For an additional review, open Settings → Draft review, save a separate TypeSafe API key and enable **Observe AI drafts with Jev**. It is off until enabled. Test Jev Connection makes a small billed TypeSafe request. The key uses the same local-file/Keychain preference as the other providers.

Observation mode reviews requested parts, edit scope, melody preservation, structural contrast, generated-vocal use and factual change summaries. Each check reports applicability, evidence sufficiency and issue probabilities, including uncertain or unassessable results. Findings never reject, repair or upgrade a generation. Jev runs after commit, independently of the next prompt; missing credentials, errors and timeouts leave applied music intact.

The pinned `jev-1.14.0` receives a bounded prompt/summary excerpt and an allowlisted symbolic report through the [official TypeSafe API](https://docs.typesafe.ai/api/system-one). Requests omit track names, audio bytes, asset metadata and file paths; user-authored prompt/summary excerpts may contain text the user included. They are capped at 24 KiB and mark shortened evidence. Each review makes one request with an eight-second timeout and no retries; at most two reviews run per project, and further overlapping observations are marked skipped. TypeSafe billing is separate from OpenAI. [Setup and limits](draft-review.md).

These measurements do not establish how the song sounds. Windows are not detected verses or drops; generated-vocal coverage includes any silence in its audio clip. Jev receives no exact note sequences or audio and must report insufficient evidence for questions requiring them. Numeric probabilities and “no concern reported” are observations, not a guarantee of musical quality. No automatic repair gate is enabled.

## Singing generation

Singing is optional and uses a separate provider from OpenAI. In Settings → Vocals:

- **Audial** accepts the melody and lyric syllables with a 5–10 second reference voice recording. Enter its API key and user ID, choose your own or a consenting singer’s reference, and save the vocal key. Check Setup validates local configuration without spending credits. Audial verifies account access on the first vocal render.
- **Rinoa (experimental)** provides stock English and Chinese singers without a reference recording. Enter a Rinoa key and use Load Singers to check access. Its API documentation and general service terms contain conflicting integration guidance; confirm permitted use before public distribution or commercial release.

Turn on singing generation, then ask, for example: “Add a sung chorus with original lyrics over this melody.” The AI can compose a melody, align syllables to notes, choose an available singer, render vocals and mix them with the instruments. Select a melody clip to specify the part to sing. Short phrases are limited to 60 seconds and 256 monophonic notes; repeated sections can reuse audio.

Vocals arrive as audio clips at the melody’s position. The source notes remain editable, and each take saves its lyrics, source score, provider and singer. Select the audio clip to inspect that information or open the source melody. To change words or notes, ask in chat and render another take. Audio keeps its original speed/pitch after tempo or note edits. WAV exports include vocals; MIDI exports include the source melody rather than the rendered voice.

API keys use the same credential store as OpenAI: the local file by default, or Keychain when enabled in Settings. Audial’s reference recording is copied into this Mac’s Application Support folder and sent only to Audial during vocal renders; it is not embedded in song documents. Both providers receive the requested score and lyrics. Their accounts, billing, retention and terms are separate from OpenAI. Failed or canceled drafts leave the song unchanged, but an accepted remote job can still consume credits. Unableton does not automatically retry vocal submissions. [Provider comparison and details](vocal-generation.md).

## Transcribe

Open Transcribe from the toolbar or Track → Transcribe, or press Shift-Command-T. Choose Whistle, Humming, Singing, or Beatboxing, then record or import a take up to 60 seconds long. Imported files are also limited to 32 MiB. The arrangement stays visible above the Transcribe pane. Choose Listen to song, Silent timeline, or Solo while recording; input monitoring stays off. Use headphones when listening to the song so it does not enter the microphone.

Use Rehearse to practice before recording, with the same listening choice and no microphone access. Pause Rehearsal pauses practice playback. The main Play button also uses the selected rehearsal mode while Transcribe is open. Follow playhead is on by default to keep your position visible during rehearsal and capture; turn it off to browse the timeline yourself. In Listen to song and Silent timeline, dots beside the track names show active clips, respecting mute and solo.

Choose the performance type, then Record. Watch the microphone level while performing and choose Stop & Transcribe when finished. The pane shows analysis progress, then the detected notes. Nothing is added until you choose Add to Song. Recording or analysis failures appear in the main pane with the next action; an empty microphone recording is reported explicitly.

Review the detected notes, drum assignments, timing, and confidence estimates. Singing mode extracts a melody, not lyrics or a new vocal recording. Detection can make mistakes, especially with noisy audio, overlapping voices, and beatboxing; Producer allows individual event corrections.

Preserve Time keeps the detected onsets, lengths, and rests without snapping. Auto-time uses the selected OpenAI model: Minor adjustments allow each onset and length to change by at most 0.25 beat, while Major adjustments can reshape the rhythm to fit the section length you choose. Both keep the reviewed pitches, note count, velocities, and event order.

Start with one performance layer for a direct transcription. Add more performance layers to play the same notes on other compatible instruments without AI composition. Matching drums, bass, harmony, and countermelody are optional AI layers. Choose each layer’s instrument, up to the song’s remaining capacity of 64 tracks. The original recording stays on the Mac; AI arrangement receives detected notes and relevant song context.

Preview Instrument auditions the result without adding it. Add to Song creates tracks at the recorded start position or another beat; when AI options are selected, the same action prepares the arrangement and adds it after validation. The new tracks are revealed in the timeline, and Play in Song starts playback at their position. The addition is one undoable edit, with the source take and reviewed transcript kept in the song package. Uninserted takes are copied to Application Support/Unableton/RecoveredTakes when closing the project or replacing the take. [Workflow, limitations, and implementation](transcription.md).

## Working on a song

The AI chat floats on the right using system Liquid Glass. The SwiftUI workspace reserves space for editing while the system background extension mirrors and blurs a decorative backdrop of the colored clips behind chat. Scrollbars and controls remain on the actual arrangement, without reflected copies. System materials follow the Mac’s appearance and accessibility settings. Drag the pane’s left edge to resize it, or focus the resize handle and use the arrow keys. Use the sidebar button or Control-Command-S to show or hide chat.

Start with a prompt such as “A high energy dubstep remix of Twinkle Twinkle.” Add follow-ups to refine the result. Track and clip selections appear above the composer; clear the selection to give whole-song context. Use the chat picker to switch conversations or create another chat on the same song.

Track names, instrument names, and track controls stay fixed on the left in an inset Liquid Glass panel. Track colors show beneath the glass as clips scroll behind it, with rounded selection and hover highlights. Headers and clip lanes scroll vertically together, keeping each track aligned with its music. Superhuman shows readable track states; Producer keeps the native editing controls.

The timeline ruler stays pinned at the top when scrolling vertically through tracks. It follows the clips when scrolling horizontally, and clicking it moves the playhead at any scroll position.

The same left panel includes the native macOS traffic lights and compact Stop, Play/Pause, Record and Loop buttons on one horizontal row. These controls remain available while scrolling and in empty songs. A native toolbar item aligns transport over the shared glass; the document title starts over the arrangement. The traffic lights retain their standard macOS close, minimize and full-screen behavior.

Timeline zoom floats over the bottom-right of the arrangement in a compact Liquid Glass control, with a slider and zoom-out/zoom-in buttons. There is no bottom status bar. Export progress and brief operation notices appear only when needed.

The timeline ruler and pinned track list begin directly below the window toolbar, without an Arrangement title row or bar-count/time-signature summary.

The arrangement supports track reordering, clip dragging between compatible tracks, duplication, splitting, trimming, and deletion. Clip dragging preserves where you grabbed the clip; a snapped preview shows its actual landing position before release. Escape cancels a move, and holding near the canvas edges scrolls the arrangement. Invalid destinations are rejected, and each completed move is one undoable edit. Dragging keeps the lower pane as it was. Double-click a lane to create a note clip. Select a clip to open the lower editor. Double-click the piano roll to add notes, drag notes to move them, or drag their right edge to resize them. Numeric controls and menu actions provide keyboard alternatives.

Sound Library includes six built-in procedural sounds—Bass, Lead, Pad, Pluck, Synth strings and Electronic drums—alongside 45 sampled presets across 42 downloadable FreePats banks. Synth controls include waveform, envelope, filter, detune, drive, and tempo-synced LFO. Tracks have volume, pan, mute, solo, and effects.

Downloadable sample instruments have finite playable ranges. Their catalog entries expose those ranges to the AI and editor; unsupported pitches produce an error instead of silent notes. The acoustic drum kit translates supported General MIDI drum pitches to its own sample keys.

Record into an audio track using the system-selected microphone or line input. Input monitoring is off. Interrupted takes retain their captured audio. Import existing recordings with File → Import Audio. Audio clips retain their original playback speed when tempo changes.

Save the song as a `.unableton` package. It contains musical metadata, audio, conversations, and generation history. File → Export WAV renders a stereo mix with release/effect tails. Export MIDI writes editable instrument parts as a multitrack Standard MIDI File; audio is kept in the project.

Useful shortcuts:

| Action | Shortcut |
| --- | --- |
| Send prompt | Command-Return |
| Show or hide AI chat | Control-Command-S |
| Transcribe a performance | Shift-Command-T |
| Add instrument track | Command-T |
| Add audio track | Option-Command-T |
| Add note clip | Shift-Command-M |
| Duplicate selection | Command-D |
| Record | Shift-Command-R |
| Stop | Command-. |
| Import audio | Shift-Command-I |
| Undo / redo | Command-Z / Shift-Command-Z |
| Play / pause | Space while the arrangement has focus |

## Development

[`AGENTS.md`](../AGENTS.md) records the product direction and engineering rules. Targets are separated into `UnabletonCore`, `UnabletonLibrary`, `UnabletonAudio`, `UnabletonDSP`, `UnabletonAI`, and the SwiftUI application. Both the UI and AI use the same validated project commands.

Audio uses AVAudioEngine, native sampler/effect units, a C++ synth, and sample-timed scheduling. Playback and offline export share the schedule. Recording transfers input through a preallocated ring into a disk writer. Rendering callbacks do not perform file I/O or run the AI.

Tests cover transactional commands, package round trips, MIDI interoperability, real offline rendering with deterministic sampler fixtures, downloadable-library transactions, timing, loops, recording handoff, musical transcription, constrained transcription arrangements, strict model tools, streaming, routing, retries, cancellation, chat queues, revision conflicts, and grouped musical undo. Tests use isolated model transports and do not need or spend an API key. Live provider and physical microphone acceptance are separate manual checks.

The project format currently uses version 1. Metadata is JSON; audio files live inside the package under UUIDs. Dates use Foundation's numeric reference-date representation to preserve subsecond precision; the reader also accepts the initial ISO 8601 representation. Newer unsupported format versions are rejected.

## Current boundaries

- Designed for macOS 26 and newer. A macOS 27 release validation pass is still required.
- One project plays or records at a time.
- Audio files are decoded into memory, with a limit of 64 million frames per file.
- Structural changes rebuild playback at the current musical position. This version does not promise seamless live graph changes.
- Local transcription handles one melodic voice or a beatbox performance. General cloud audio understanding, polyphonic transcription, lyric transcription, third-party plugin hosting, external MIDI recording, advanced time stretching, comping, and sampled orchestral strings are not included.
- Source publication does not provide a signed distribution release. Developer signing, notarization, and release packaging are separate work.

## License

Application code is [Apache 2.0](../LICENSE). Downloaded instruments retain their own licenses; see [third-party notices](../THIRD_PARTY_NOTICES.md). Large sound banks and personal song files are excluded from Git.
