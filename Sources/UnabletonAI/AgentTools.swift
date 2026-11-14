import Foundation
import UnabletonCore

enum AgentTools {
    static func object(_ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(properties.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    static func type(_ value: String) -> JSONValue { .object(["type": .string(value)]) }
    static func nullable(_ schema: JSONValue) -> JSONValue { .object(["anyOf": .array([schema, type("null")])]) }
    static func array(_ item: JSONValue) -> JSONValue { .object(["type": .string("array"), "items": item]) }
    static func noteArray(_ item: JSONValue) -> JSONValue { .object(["type": .string("array"), "items": item, "maxItems": .number(64)]) }
    static func enumeration(_ values: [String]) -> JSONValue { .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))]) }
    static let string = type("string"), number = type("number"), integer = type("integer"), boolean = type("boolean")
    static let note = object(["id": nullable(string), "pitch": integer, "startBeat": number, "duration": number, "velocity": integer])
    static let clip = object([
        "id": string, "name": string, "kind": enumeration(["notes", "audio"]), "startBeat": number, "lengthBeats": number,
        "notes": noteArray(note), "assetID": nullable(string), "sourceOffsetSeconds": number
    ])
    static let track = object([
        "id": string, "name": string, "kind": enumeration(["instrument", "audio"]), "instrumentID": string,
        "colorIndex": integer, "volume": number, "pan": number, "isMuted": boolean, "isSolo": boolean, "isArmed": boolean,
        "parameters": array(object(["id": string, "value": number])), "clips": array(clip)
    ])
    static let command = object([
        "op": enumeration(CommandOperation.allCases.map(\.rawValue).filter { $0 != "addAsset" }),
        "trackID": nullable(string), "clipID": nullable(string), "noteID": nullable(string), "targetTrackID": nullable(string),
        "track": nullable(track), "clip": nullable(clip), "note": nullable(note), "notes": nullable(noteArray(note)),
        "value": nullable(number), "text": nullable(string), "index": nullable(integer), "startBeat": nullable(number), "lengthBeats": nullable(number)
    ])
    static func tool(_ name: String, _ description: String, _ parameters: JSONValue) -> JSONValue {
        .object(["type": .string("function"), "name": .string(name), "description": .string(description), "strict": .bool(true), "parameters": parameters])
    }
    static let definitions: [JSONValue] = [
        tool("get_project", "Read the current editable draft, including selected IDs and clip summaries. This is authoritative even when older chat messages describe another version.", object([:])),
        tool("get_clip", "Read notes or audio metadata for a clip. start_index is zero based and count is 1–4096.", object(["clip_id": string, "start_index": integer, "count": integer])),
        tool("get_instruments", "List built-in and downloadable instruments, installation status, sizes, musical roles, supported parameters and drum mappings. Read before choosing sounds. The host handles required downloads; never invent download URLs.", object([:])),
        tool("apply_edits", "Atomically edit the draft with typed music commands, at most 64 note events per batch. Set new notes' id to null; the host assigns IDs. Build short phrases then extend with repeatClip and transformations. Fields irrelevant to an operation must be null. No live project changes occur until this run succeeds. Return IDs are available for follow-up edits.", object(["commands": array(command)])),
        tool("render_preview", "Render up to 64 beats of the draft locally and measure level, clipping and silence. Returns numerical analysis, not an auditory judgement. start_beat and length_beats use quarter-note beats.", object(["start_beat": number, "length_beats": number]))
    ]

    static let vocalDefinitions: [JSONValue] = [
        tool("get_vocal_singers", "List available singing voices from the configured provider. Use the exact name as singer_id. Vocal generation sends the score and lyrics to that provider and consumes its credits.", object([:])),
        tool("generate_vocals", "Sing an existing monophonic note clip with one lyric syllable per chronological note (or '-' for a held syllable). Up to 60 seconds, 256 notes, MIDI 36–96. Keeps the editable melody and stores lyrics/score with the resulting audio. Adds the vocal at the source clip start. target_track_id:null creates a new audio track. Audio does not retune or time stretch when notes/tempo later change; regenerate after such edits. Provider failures stop the run without committing any edits.", object([
            "melody_clip_id": string, "singer_id": string, "lyrics": array(string), "track_name": string, "target_track_id": nullable(string)
        ]))
    ]
    static let vocalInstructions = """

    Singing generation is enabled. When the user asks for vocals, call get_vocal_singers, choose an appropriate returned voice, compose or inspect a monophonic melody note clip and call generate_vocals with exactly one lyric syllable for each note in chronological order. Use '-' only to sustain the previous syllable on a contiguous following note. Write original lyrics if requested or unspecified; preserve supplied lyrics. Never use speech synthesis as a substitute for singing. The host renders the supplied melody and lyrics with the separate vocal provider; do not invent singer IDs or URLs. Work in short phrases of at most 60 seconds. Melody timing must fall on 1/960 beat ticks; quantize source notes if needed before synthesis. Do all note and tempo edits BEFORE rendering vocals. If you create a dedicated vocal guide track, mute it after rendering unless the user wants it audible. Preserve pre-existing instrument parts unless asked to change them. Reuse or duplicate rendered clips for repeated sections instead of buying identical takes repeatedly. To replace a vocal, generate the replacement first then explicitly delete the old audio clip. Read an existing vocal asset's saved vocalTake.score/lyrics in get_project to revise its words. Retain the source melody so notes remain editable. Do not claim rendered vocals automatically follow later score or tempo changes. The user has enabled use of the configured provider; keep your summary clear about the vocal clips actually created.
    """

    static func summary(song: Song, selection: ProjectSelection) throws -> JSONValue {
        struct ClipSummary: Encodable { var id: UUID; var name: String; var kind: ClipKind; var startBeat: Double; var lengthBeats: Double; var noteCount: Int; var assetID: UUID? }
        struct TrackSummary: Encodable { var id: UUID; var name: String; var kind: TrackKind; var instrumentID: String; var volume: Double; var pan: Double; var isMuted: Bool; var isSolo: Bool; var isArmed: Bool; var parameters: [String: Double]; var clips: [ClipSummary] }
        struct Summary: Encodable { var revision: Int; var title: String; var tempo: Double; var key: String; var beatsPerBar: Int; var lengthBars: Int; var loopEnabled: Bool; var loopStart: Double; var loopEnd: Double; var selection: ProjectSelection; var tracks: [TrackSummary]; var assets: [AudioAsset] }
        return try JSONValue.encode(Summary(revision: song.revision, title: song.title, tempo: song.tempo, key: song.key, beatsPerBar: song.beatsPerBar, lengthBars: song.lengthBars, loopEnabled: song.loopEnabled, loopStart: song.loopStart, loopEnd: song.loopEnd, selection: selection, tracks: song.tracks.map { t in
            TrackSummary(id: t.id, name: t.name, kind: t.kind, instrumentID: t.instrumentID, volume: t.volume, pan: t.pan, isMuted: t.isMuted, isSolo: t.isSolo, isArmed: t.isArmed, parameters: t.effectiveParameters, clips: t.clips.map { ClipSummary(id: $0.id, name: $0.name, kind: $0.kind, startBeat: $0.startBeat, lengthBeats: $0.lengthBeats, noteCount: $0.notes.count, assetID: $0.assetID) })
        }, assets: song.assets))
    }

    static func commands(from args: JSONValue) throws -> [ProjectCommand] {
        guard let values = args["commands"]?.arrayValue, !values.isEmpty, values.count <= 128 else { throw AgentError.invalidTool("Send 1–128 commands in an edit batch.") }
        let normalized = try values.map { value -> JSONValue in
            guard case .object(var command) = value else { throw AgentError.invalidTool("Each command must be an object.") }
            if case .object(var track) = command["track"] {
                var parameters: [String: JSONValue] = [:]
                guard let pairs = track["parameters"]?.arrayValue else { throw AgentError.invalidTool("Track parameters must be an array of {id,value} pairs; use [] for defaults.") }
                for pair in pairs {
                    guard let id = pair["id"]?.stringValue, let v = pair["value"]?.doubleValue else { throw AgentError.invalidTool("Instrument parameters require id and value.") }
                    parameters[id] = .number(v)
                }
                track["parameters"] = .object(parameters)
                if let clips = track["clips"]?.arrayValue { track["clips"] = .array(try clips.map(normalizeClip)) }
                command["track"] = .object(track)
            }
            if case .object = command["clip"] { command["clip"] = try normalizeClip(command["clip"]!) }
            if case .object = command["note"] { command["note"] = try normalizeNote(command["note"]!) }
            if let notes = command["notes"]?.arrayValue { command["notes"] = .array(try notes.map(normalizeNote)) }
            // Only the dedicated vocal tool may create trusted audio; edits reference existing assets.
            command.removeValue(forKey: "asset")
            return .object(command)
        }
        let commands = try JSONValue.array(normalized).decode([ProjectCommand].self)
        let notes = commands.reduce(0) { count, c in count + (c.notes?.count ?? 0) + (c.note == nil ? 0 : 1) + (c.clip?.notes.count ?? 0) + (c.track?.clips.reduce(0) { $0 + $1.notes.count } ?? 0) }
        guard notes <= 64 else { throw AgentError.invalidTool("Send at most 64 note events per batch. Compose a short phrase, then use repeatClip, transpose, quantize or humanize to develop longer sections.") }
        return commands
    }

    private static func normalizeNote(_ value: JSONValue) throws -> JSONValue {
        guard case .object(var note) = value else { throw AgentError.invalidTool("Each note must be an object.") }
        if note["id"] == .null { note["id"] = .string(UUID().uuidString) }
        return .object(note)
    }
    private static func normalizeClip(_ value: JSONValue) throws -> JSONValue {
        guard case .object(var clip) = value else { throw AgentError.invalidTool("Each clip must be an object.") }
        if let notes = clip["notes"]?.arrayValue { clip["notes"] = .array(try notes.map(normalizeNote)) }
        return .object(clip)
    }

    static let instructions = """
    You compose and edit music inside Unableton, a native macOS music workstation. Make real editable music with notes, instruments and drum parts through the supplied tools. Do not substitute a description for requested musical edits or claim a change was applied before tools succeed. The host automatically applies the complete valid draft at the end as one undoable edit. It discards drafts on failure. No approval is needed for these reversible music edits.
    Accept short or complex requests. Infer reasonable musical choices when unspecified. Preserve existing content unless the user asks to change it. Selection gives the intended edit scope when relevant. Read current project and instruments, inspect existing notes before changing them, and develop melody, harmony, rhythm, arrangement, dynamics and timbre to suit the request. Compose short 1–4 bar phrases in small tool batches with at most 64 note events total per batch. Extend phrases into longer arranged sections with repeatClip, duplicateClip, transpose and humanize, adding contrasting phrases, fills and instrumentation for variation. Do not emit a whole 32-bar song as one enormous note array or manufacture a UUID for every new note. If referencing a familiar public-domain melody, write actual recognisable notes and develop the requested arrangement around it.
    Timing is quarter-note beats: startBeat on a clip is global, but notes' startBeat is relative to the clip. Pitch is MIDI 0–127, velocity 1–127, duration is in beats. Follow each instrument's minimumPitch and maximumPitch from the catalog; sampled instruments can have a limited playable register. Transpose or choose another instrument rather than placing notes outside its range. New tracks and clips need unique UUID strings in id. For every NEW note set id:null; the host creates a unique stable ID. Preserve an existing note's UUID when editing it, and get_clip supplies existing note IDs when needed. updateNote targets noteID and always retains that target's identity. Use supplied instrument IDs only; loaded instruments determine sound. Follow each percussion preset's supportedPitches, description and pitchMap; downloaded kits may use native keys rather than General MIDI. Only drums.electronic and sampled.drums use these project General MIDI keys: 36 kick, 38 snare, 39 clap, 42 closed hat, 46 open hat, 49 crash, 51 ride, 45 low tom, 47 mid tom, 50 high tom. Clips on instrument tracks have kind notes; clips on audio tracks have kind audio with an existing assetID. Never invent an audio asset. Singing requires the supplied vocal tools; otherwise arrange recorded/imported vocal audio only.
    apply_edits commands use these fields, with irrelevant fields null:
    addTrack: track (may include initial clips), index optional. deleteTrack/duplicateTrack: trackID. reorderTrack: trackID,index. renameTrack: trackID,text. setInstrument: trackID,text instrument ID. setParameter: trackID,text parameter ID,value (volume 0–1.5 or pan -1–1 are also valid). setMute/setSolo/setArmed: trackID,value 0 or 1; arm audio tracks only.
    addClip: trackID,clip. deleteClip: clipID. duplicateClip: clipID,startBeat optional. repeatClip: clipID,index number of additional copies, startBeat optional. moveClip: clipID,startBeat,targetTrackID optional. trimClip: clipID,startBeat optional,lengthBeats optional. splitClip: clipID,startBeat global split position. replaceNotes: clipID,notes. addNote: clipID,note. updateNote: clipID,noteID,note. deleteNote: clipID,noteID. transpose: clipID,value semitones. quantize: clipID,value grid in beats. humanize: clipID,value 0–0.25 beats. setTempo:value 30–300 BPM. setLength:index bars. setKey:text. setLoop:startBeat,lengthBeats,value 0 or 1. setMetronome:value 0 or 1.
    Instruments marked built-in work offline. Downloadable instruments may require user consent and installation before edits complete; never claim a missing sound is already installed or substitute another sound silently.

    Never write pitches listed in a preset's unrenderablePitches; those remain recognized only for old document compatibility.
    A track parameters field is an array of {id,value} pairs. Use empty parameters for preset defaults. Instrument parameters on acoustic samples differ from synth parameters: follow the catalog. Synth LFO rates are cycles per beat. Set sensible levels; avoid excessive clipping. render_preview measures the draft, but you cannot hear its audio. Do not describe the metrics as listening or pretend to judge vocal content. Finish with a brief plain-language summary of the actual edits. If only asked a question, answer without changing the project.
    """
}
