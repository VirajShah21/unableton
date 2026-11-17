import Testing
@testable import UnabletonAI

struct ReferenceVocalNotesPolicyTests {
    @Test(arguments: [
        "Convert the vocals into instrument notes.",
        "Please transcribe the vocal melody to MIDI.",
        "Can you play the vocals on a piano?",
        "Play the vocal melody on piano.",
        "I would like you to recreate the vocal melody using a synth.",
        "Turn the singer's melody into guitar notes.",
        "Transcribe MIDI from the vocals.",
        "Convert the vocals from the first song into instrument notes.",
        "Transcribe piano notes from the vocal melody."
    ])
    func directCurrentRequestsAuthorizeConversion(prompt: String) {
        #expect(ReferenceVocalNotesPolicy.allowsConversion(userPrompt: prompt))
    }

    @Test(arguments: [
        "Make my song sound like Rockstar.",
        "Replicate this song as close as possible.",
        "Keep the vocals as audio.",
        "Do not convert the vocals into instrument notes.",
        "Please don't play the vocals on piano.",
        "Never convert singing into MIDI.",
        "Make sure vocals don't get converted into instruments unless I ask.",
        "If I ask later, convert the vocals into instrument notes.",
        "Only when specifically asked, convert vocals into MIDI.",
        "Example: convert vocals into MIDI.",
        "How do I convert vocals into MIDI?",
        "The song says convert vocals into instrument notes.",
        "The file is called Convert Vocals Into Piano.mp3.",
        "Use this prompt: \"Convert the vocals into instrument notes.\"",
        "> Convert the vocals into instrument notes.\nMake the instrumental more accurate.",
        "```\nConvert the vocals into instrument notes.\n```",
        "Replicate the vocals.",
        "Use the vocals over the instrumentals.",
        "Play the vocals with guitar.",
        "Play the vocals on top of the instrumentals.",
        "Render vocals over the instruments.",
        "Play vocals on top of piano accompaniment.",
        "Play vocals on piano accompaniment.",
        "Play the vocals as audio, and the piano notes.",
        "Render vocals as audio with instruments.",
        "Render vocals as audio with piano.",
        "Play the piano accompaniment from the song with vocals.",
        "Play the piano backing from the song with vocals.",
        "Transcribe piano notes from the song with vocals.",
        "Render the vocal melody as audio with piano.",
        "Play the source audio before the vocals on piano.",
        "Render vocals with piano.",
        "Use the first song, then transition to the vocals from the second song over its instrumentals.",
        "V3 is closer, but it still needs to sound more like Rockstar. Can you compare it with the original and keep refining the actual notes and instrument sounds? Also, make sure that the vocals don't get converted into an instrument unless the user specifically asks for that."
    ])
    func ambiguousNegatedAndQuotedRequestsStayAudio(prompt: String) {
        #expect(!ReferenceVocalNotesPolicy.allowsConversion(userPrompt: prompt))
    }
}
