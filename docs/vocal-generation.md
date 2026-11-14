# Vocal generation

Research checked November 12, 2026. These are integration choices, not an audible quality benchmark: no paid provider has been compared in a blind listening test.

| Option | Lyrics and exact melody | Integration decision |
| --- | --- | --- |
| Audial text2vox | Monophonic MIDI, per-note syllables, reference voice; returns vocal WAV and MIDI | Recommended hosted provider. Public API and explicit output/commercial-use terms. Requires a 5–10 second reference voice owned by or consented to by the user. |
| Rinoa | MusicXML or lyric-annotated MIDI; stock English/Chinese singers; streamed WAV output | Optional experimental provider. Good score-based interface without a reference recording; public API and general terms need reconciliation before public release. |
| ACE Studio | Desktop MIDI/lyrics singing editor | No public synthesis endpoint contract found suitable for implementation. The vendor asks developers to contact it about API integration. Do not call its private desktop endpoints. |
| OpenVPI DiffSinger / OpenUtau | Score-conditioned singing with a suitable voicebank | Strong future local option. DiffSinger code is Apache 2.0 and OpenUtau is MIT, but model/voicebank licenses are separate. Requires phonemizer, model packaging, singer selection, and native-runtime work. |
| SoulX-Singer | Score or melody conditioning with reference voice and metadata | Promising open-source research route; Python/PyTorch inference and model preparation make it a larger deployment project than a native HTTP client. |
| Eleven Music | Lyrics and style/audio guidance | Useful for full-song generation, but its documented reference flow guides style rather than faithfully copying a supplied melody. It does not replace an editable score-to-singing workflow here. |

## Sources and terms

- Audial: [Text to Vocal](https://www.audialmusic.ai/tools/text-to-vocal), [MIDI workflow](https://www.audialmusic.ai/tools/midi-to-vocals), [API](https://www.audialmusic.ai/resources/api-reference), [official SDK](https://github.com/AudialAI/audial-sdk), [terms](https://www.audialmusic.ai/legal/terms). The product page lists two trial renders, then $10/month or $100/year. Its terms preserve user input rights and grant ownership/commercial use of outputs subject to input rights. Voice consent is required. Unableton is a client using the user's own key; it does not resell API access or bundle Audial plugin code.
- Rinoa: [HTTP contract](https://rinoa.ai/docs/api/http), [key setup](https://rinoa.ai/docs/api/), [plans](https://rinoa.ai/pricing/subscription), [FAQ](https://rinoa.ai/company/faq), [terms](https://rinoa.ai/company/terms). API requests use the account's normal credits. The site advertises Free as personal/noncommercial without downloads and paid commercial tiers. Our authenticated Free-account API test nevertheless returned a valid WAV; do not infer paid/commercial rights from that technical result. General terms include automation/competition restrictions while API docs explicitly describe third-party DAW integration. This is unresolved documentation, not a blanket assertion of permission. Do not imply that Apache licensing of Unableton grants rights to a provider's models, voices, or output.
- ACE: [custom voice and integration FAQ](https://acestudio.ai/custom-voice/).
- Local candidates: [DiffSinger](https://github.com/openvpi/DiffSinger), [OpenUtau](https://github.com/openutau/OpenUtau), [SoulX-Singer](https://github.com/Soul-AILab/SoulX-Singer).
- Full-song alternative: [Eleven Music capabilities](https://elevenlabs.io/docs/overview/capabilities/music).

## Workflow and limits

OpenAI composes or inspects notes, then uses `get_vocal_singers` and `generate_vocals`. The latter references an existing note clip and provides one lyric syllable per chronological note; `-` sustains the previous syllable. The host validates pitch, monophony, exact beat grid, lyric alignment, duration and voice before submitting synthesis. It never asks the model to invent binary audio or download URLs.

The draft contains new audio metadata; a prompt-scoped cache owns the downloaded bytes. Local previews include those bytes. After revision validation, the document installs them and applies all musical changes as one undo step. Undo preserves the conversation and audio bytes for redo. Saving embeds generated WAV audio plus the source score, lyrics, provider, singer and creation date. Older format-1 documents without vocal metadata still open.

The source clip determines placement; rendered audio starts at that clip's start and includes the score's initial rests. Requests are limited to 60 seconds, 256 notes, MIDI 36–96, 1/960-beat timing, four submissions and 64 MiB per prompt. Downloads are bounded to 32 MiB each, decoded, duration-checked and rejected if empty, silent or malformed. Rinoa multi-file output has no documented per-file offsets, so it is rejected rather than guessed; request a shorter phrase.

Completed identical score/voice renders are reused within a prompt, including a model upgrade or manual-edit replan. Vocal POSTs are never automatically retried. Provider errors terminate the draft; model upgrades do not retry a failed vocal job. Cancellation stops local work, but neither integration promises cancellation/refunds of already-accepted provider jobs.

Keys and Audial's local reference recording are excluded from song documents. Lyrics and score remain in local project/conversation context and are sent to the selected providers as needed. Remote processing follows each provider's own retention and service policies. This feature does not implement audio understanding or claim that OpenAI listened to the generated take.

## Live test result

A personal Free-account Rinoa API test on November 12 returned a real 4.005-second mono 44.1 kHz/16-bit WAV of the supplied seven-note Twinkle phrase using English: Female Soprano. The source score and aligned lyric syllables remained in the project. The local preview was non-silent and unclipped; native undo/redo and save/reopen retained the take. This establishes the exercised API path, not a listening benchmark or a commercial license grant. A first attempt exposed an advisory-format metadata mismatch; the client now validates the returned file bytes rather than rejecting a WAV based on that label.
