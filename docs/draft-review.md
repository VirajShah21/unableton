# Draft review

Local analysis runs after successful chat generation and insertion of an AI transcription arrangement. It compares the actual baseline with the applied draft, including for answers that make no musical edits. Faithful offline transcription does not invoke Jev or create an AI generation record.

The analysis measures:

- Added, deleted, changed and unchanged track/clip IDs, exact note-array changes, track moves/reordering, selection facts and changed global fields. Revision counters are not musical edits.
- Stored note/drum counts, catalog instrument categories, pitch ranges and pitch classes. Mixer eligibility accounts for mute, solo and volume; it does not prove a rendered track is audible.
- Interval-union activity clipped to note/clip boundaries and available audio duration, and generated-vocal coverage identified from saved provenance.
- Repeated stored note patterns, independent of UUIDs and placement, and up to 32 uniform timeline windows. These are not inferred musical sections or perceptual similarity measurements.

Detailed processing is bounded to 64 tracks and 262,144 notes per snapshot. Each entity-ID list contains at most 256 IDs with exact full counts. Truncation and limitations are included in the report. Compute it off the main actor and never in an audio callback. Reports do not analyze timbre, lyric intelligibility, harmonic suitability or genre quality.

## Setup

Settings → Draft review exposes a separate TypeSafe key, Save, Remove and Test Jev Connection, plus Observe AI drafts with Jev. The preference defaults off. Keys use the existing private local file by default or Keychain only after the app-wide explicit opt-in. Switching storage never moves credentials. No real TypeSafe key is bundled or required for tests.

The connection test makes one small TypeSafe API request, with separate provider billing. Provider details: [API](https://docs.typesafe.ai/api/system-one), [Noul questions](https://docs.typesafe.ai/primitives/noul), [models](https://docs.typesafe.ai/models).

## Observation behavior

After commit, the optional reviewer receives a compact allowlisted projection of local analysis plus bounded excerpts of the original prompt and actual composer summary. Track names, audio, lyrics from assets, file paths and audio metadata are excluded; prompt text can itself contain names, lyrics or paths supplied by the user. No whole song, API key or Responses continuation is embedded in review state.

The native client posts directly to `https://api.typesafe.ai/v1/systemone` with pinned `jev-1.14.0`. It batches six criteria: requested parts, edit scope, melody preservation, structural contrast, generated-vocal use and summary accuracy. Each criterion asks independent applicability, evidence sufficiency and issue questions. No global music-quality score or accept/repair action is returned.

Display statuses are provisional observation labels: not requested, insufficient evidence, possible issue, no concern reported or uncertain. They use conservative 0.3/0.7 bands, not thresholds validated for autonomous musical decisions. Exact note sequences and audio are absent, so new-melody recognition, listening judgments and many ambiguous requirements cannot be established. User text and model claims are data, not reviewer instructions.

Requests are at most 24 KiB including questions; prompt and summary excerpts use byte limits. Detail is reduced as complete JSON facts, never by slicing encoded JSON. Reports identify truncated context. Responses are capped at 2 MiB and must contain every expected named Noul answer, finite probabilities in 0–1, a model ID and valid token usage. Error bodies and credentials are never copied into history.

Each review has one request, an eight-second deadline and no automatic retry. At most two run concurrently per project; excess observations are marked skipped. A missing key, timeout, malformed response or provider error records an unavailable observation while keeping the successful generation. Closing cancels pending reviews; persisted pending observations reopen as interrupted, without silently contacting TypeSafe. Queued composition, Undo, playback and later edits do not wait for Jev.

Expand Draft analysis in chat to inspect and copy the report. Local facts, review version/model, probabilities, timing, usage and truncation flags are optional generation metadata in version-1 project packages. Undo marks the generation undone without deleting its report or conversation. Composer and reviewer usage remain separate.

## Shared generation limits

The composer and optional transcription arranger use a run-scoped actor with a monotonic deadline. The same actor survives the one allowed revision replan and automatic model upgrade. The hard caps are five minutes, 32 model requests, 65,536 generated output tokens and two transient retries total. Backoff, retries and discarded successful responses consume the same allowance. Once Automatic upgrades to Astra, a replan stays there. Explicit model choices remain fixed.

Prepare generated assets and waveform data before the last deadline/revision check. Commit the complete validated transaction without an intervening suspension. Local analysis and cloud observation happen afterward so they cannot discard a completed draft. Vocal submissions retain their separate limits, cache and prohibition on blind paid retries.

## Evaluation boundary

Automated tests use fake composer/reviewer transports and isolated credentials. They establish deterministic analysis, bounded request/response handling, observation-only behavior, persistence, cancellation, queue independence, budgets and retries. They do not establish Jev's accuracy on music or listening preference. Before enabling any repair gate, evaluate held-out good/bad drafts, false accept/reject rates, total cost/latency and blinded human listening comparisons.
