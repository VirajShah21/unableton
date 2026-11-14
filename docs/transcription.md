# Transcribe

Transcribe turns a recorded or imported performance into editable instrument notes or drum hits. Audio analysis runs on the Mac. The default path does not need an API key or an internet connection.

Open the toolbar’s Transcribe button, Track → Transcribe, or Shift-Command-T. The lower pane opens while the arrangement remains visible above it.

## Record or import a take

Choose a mode:

| Mode | Detected content |
| --- | --- |
| Whistle | One whistled melody. |
| Humming | One hummed melody. |
| Singing | One sung melody, converted to instrument notes. Lyrics and a generated singing voice are not part of this mode. |
| Beatboxing | Percussive onsets with estimated kick, snare and closed hi-hat assignments. You can change the drum assignments in review. |

Choose what to hear while recording:

| Option | Behavior |
| --- | --- |
| Listen to song | Hear the song and follow its moving playhead as you perform. Use headphones to keep accompaniment out of the microphone. |
| Silent timeline | Follow the arrangement and playhead with song output muted. |
| Solo | Record without the song or metronome; the playhead still shows the position of the take. |

Use Rehearse to practice before recording. Rehearsal uses the selected listening option without opening the microphone or requesting microphone permission. Pause Rehearsal pauses it. The main Play/Pause control also follows that listening choice while Transcribe is open, and seeking keeps the selected mode. Starting playback outside Transcribe uses the normal song output.

Follow playhead is on by default. It keeps the current position visible during rehearsal and capture; turn it off to scroll elsewhere without the view following. In Listen to song and Silent timeline, small dots in the fixed track headers identify clips active at the playhead, respecting track mute and solo. These are timeline activity indicators, not audio level meters. Solo audition does not mark accompaniment as active.

Input monitoring is off in all three modes. Record take starts from the current transport position. Stop take finishes the recording; takes are limited to 60 seconds. The system-selected microphone or line input is used, and macOS requests permission when capture is started.

The folder button imports an existing audio file up to 60 seconds long and 32 MiB in size. Its initial insertion position is the playhead position when the file was chosen. Imported files use the same analysis and review workflow as new recordings.

Use a clear, single performance. Accompaniment through speakers, multiple voices, breath noise and noisy recordings can cause extra, missed or incorrect events. Transcribe does not separate a full mix into instruments.

## Review the events

The Notes tab shows detected pitches or drum types, start times, lengths and confidence scores. Correct pitches, drum assignments, starts and lengths before inserting. You can also edit the resulting notes later in the piano roll.

Confidence is a detector quality estimate, not a probability that a note is correct. Beatbox classification uses signal features rather than a trained beatbox model; review its kick, snare and hi-hat labels. Singing mode detects melody notes, not sung words.

Listen to original take auditions the captured audio. The take menu also offers Save Original Take and Analyze Take Again. Selecting another mode analyzes the same take again and resets its layer choices.

## Choose timing

Choose timing after recording, in the Timing tab:

| Option | Behavior |
| --- | --- |
| Preserve Time | Keep the reviewed event onsets, lengths and rests. No snapping or added notes. |
| Auto-time: Minor adjustments | AI can move each onset and change each length by at most 0.25 beat, or one sixteenth note. |
| Auto-time: Major adjustments | AI can reshape the rhythm to fit the section length you choose and the surrounding song. |

Both Auto-time options retain the reviewed pitches, event count, velocities and order. Major adjustments keep events inside the chosen section; melodic events remain one voice. Section length is entered in beats. In 4/4, 16 beats is four bars.

Preserve Time preserves the detector’s measured timing, which is an estimate of the performance. It converts seconds directly to beats at the current song tempo when preparing the insertion. The resulting MIDI notes follow later song-tempo changes as normal instrument parts.

Leave Insert where recording started enabled to use the take’s original song position. Turn it off to enter another beat or choose Use Current Playhead. Moving the insertion point does not remove leading silence or change the spaces between events.

## Choose layers

The default is one Detected performance layer. This plays the reviewed notes on a chosen compatible instrument, with no extra composition. Increase Performance layers to copy those same notes onto other instruments. Copies work offline and do not ask the model to guess additional parts.

Add Layer can request Matching drums, Matching bass, Harmony or Countermelody. These are AI accompaniment layers. Choose each layer’s instrument and name; optional arrangement instructions describe the accompaniment you want. At least one detected-performance layer remains in the result.

The song can contain up to 64 tracks in total. The pane shows how many track slots remain. Instrument choices must support the detected pitches or drum keys; Unableton does not silently transpose the performance to fit a sample bank.

Auto-time and accompaniment use the OpenAI model selected in Settings. Automatic mode starts with GPT-6 Luna and can upgrade once to GPT-6 Astra; fixed selections stay fixed. AI options send detected notes, timing choices, requested layers and relevant song context. The recording itself is not uploaded. The preview shows model usage and an upgrade reason when one occurred.

## Preview and add to the song

The pane guides you through Record, Review and Add. Whistle is the initial mode; all four performance choices are visible before recording. During capture, check the microphone level and use Stop & Transcribe. Analysis runs automatically after stopping, with progress in the main pane. Recording alone does not add a track.

Preview Instrument or Preview Arrangement renders the draft at the chosen position with the song without adding tracks. Add to Song prepares selected AI options when needed, validates them and adds the selected tracks through the shared commands as one undo step. You do not need to preview first. Successful additions come into view in the arrangement; Play in Song hears them with the song from their insertion position, regardless of the listening option used during capture.

Failures show the actual error in the main pane. For a nonempty take, Retry Analysis, Listen to Recording and Save Recording help you recover. No-input or empty recordings explain that audio was not captured and require another take; changing the melody mode cannot recover an empty file.

If the song or transcription settings change after preview, Add to Song prepares the updated settings as needed. A concurrent song edit can cause one replan; another conflict stops the operation and keeps the take. Cancellation or an invalid AI result leaves the song unchanged.

The inserted instrument clips retain editable notes and sound settings. The song package also keeps the source audio, reviewed transcript, capture tempo and original start position. AI-assisted insertions keep their summary and model usage in a project chat. Undo removes the musical insertion together; conversation history remains available.

WAV export renders the instrument parts. MIDI export includes their editable notes. The retained source take is reference audio and does not create an audible audio track automatically.

## Keep an uninserted take

Before replacing a take or closing its project, Unableton copies an uninserted take and its metadata to:

```text
~/Library/Application Support/Unableton/RecoveredTakes
```

Use Show Recovered Takes from the take menu to open that folder, or open it through Finder. A recovered audio file can be imported into Transcribe again; choose its insertion position in the new review. Save Original Take writes a separate copy to a location you choose. Recovery errors are shown rather than treated as a successful save.

## Implementation and limits

- `UnabletonAudio` decodes and analyzes a bounded mono signal away from audio callbacks. Melodic modes use a native pitch detector based on [YIN, a fundamental frequency estimator for speech and music](https://doi.org/10.1121/1.1458024), by Alain de Cheveigné and Hideki Kawahara. Note timing is estimated from pitch and energy frames; MIDI pitches are whole semitones.
- Beatboxing uses onset energy and frequency-band features. It is a small, reviewable heuristic, not a learned classifier. The detector does not generate missing musical material.
- `UnabletonCore` owns measured events, validation, timing/layer options, source provenance and command construction. A take is limited to 60 seconds and 4096 detected events; imported files are limited to 32 MiB. Each output layer is limited to 4096 notes and the song retains its existing 64-track limit.
- `UnabletonAI` uses one strict arrangement tool. The model can propose timing changes for known source-event IDs and notes for explicitly requested accompaniment-layer IDs. Host validation rejects changes outside the selected timing policy, unrequested layers and unsupported instrument pitches. It cannot edit the existing song through this tool.
- [Spotify Basic Pitch](https://github.com/spotify/basic-pitch) was considered as a future neural transcription option. It already offers a Core ML model and supports polyphonic notes, but is not bundled or used by this implementation. General [OpenAI speech transcription](https://developers.openai.com/api/docs/guides/speech-to-text) returns words and is not used to obtain musical notes.

Two physical microphone Whistle runs passed recording, review, preview and insertion, using synthetic whistle playback through the Mac speakers. Human whistle, humming, singing and beatboxing accuracy, accompaniment bleed, permission denial and input-device interruptions remain release checks. Synthetic fixtures do not establish real-performer accuracy. See [verification](verification.md) for the checks actually completed.
