import Foundation

/// Conservative authorization from the submitted user message only. Tool
/// arguments, filenames and old chats cannot enable vocal melody conversion.
/// Ambiguous requests keep vocals as audio and can be clarified in chat.
public enum ReferenceVocalNotesPolicy {
    public static let requestExample = "Convert the vocals into instrument notes."

    public static func allowsConversion(userPrompt: String) -> Bool {
        var text = userPrompt.lowercased().replacingOccurrences(of: "’", with: "'")
        // Examples, quotes and code are data, not authorization.
        for pattern in [#"(?s)```.*?```"#, #"(?m)^\s*>.*$"#, #"`[^`]*`"#, #"[\"“][^\"”]*[\"”]"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let vocal = #"\b(?:vocal melody|singer's melody|vocals?|singing)\b"#
        let target = #"\b(?:(?:instrument(?:al)? notes?|instruments?)|midi|piano|synth(?:esizer)?|guitar|bass|strings|flute|violin|keyboard|notes)\b"#
        let action = #"\b(?:convert|transcribe|turn|map|render|recreate|replicate|play)\b"#
        for clause in text.components(separatedBy: CharacterSet(charactersIn: ".!?;\n")) {
            guard clause.range(of: vocal, options: .regularExpression) != nil else { continue }
            // Do not guess around negation, conditions or reported requests.
            if clause.range(of: #"\b(?:not|no|never|don't|dont|do not|without|avoid|unless|if|when|asks?|asked|says?|said|example|how|whether|explain|describe|quote|quoted|suggest|consider|maybe)\b"#, options: .regularExpression) != nil { continue }
            let direct = #"^\s*(?:(?:please|also|then|and|now|can you|could you|would you|i want you to|i would like you to|i'd like you to|i want to|i'd like to)\s+)*"#
            let modifiers = #"\s+(?:(?:a|an|the|editable|pitched|melodic)\s+){0,3}"#
            let sourcePrefix = #"\s+(?:(?:the|this|that|original|attached|separated)\s+){0,3}"#
            let sourceQualifier = #"(?:\s+(?:from|of|in)\s+(?:(?:the|this|that|first|second|attached)\s+){0,2}(?:song|reference|attachment))?"#
            let source = sourcePrefix + vocal + sourceQualifier
            let destination = modifiers + target + #"(?!\s+(?:accompaniment|backing|audio)\b)"#
            let forward = direct + action + source + #"\s+(?:into|to|as|on)\b"# + destination
            let melodySource = sourcePrefix + #"\b(?:vocal melody|singer's melody)\b"# + sourceQualifier
            let explicitMelody = direct + action + melodySource + #"\s+(?:with|using)\b"# + destination
            let reverse = direct + action + destination + #"(?:\s+(?:melody|notes))?\s+(?:from|of)\b"# + source
            if clause.range(of: forward, options: .regularExpression) != nil || clause.range(of: explicitMelody, options: .regularExpression) != nil || clause.range(of: reverse, options: .regularExpression) != nil { return true }
        }
        return false
    }
}
