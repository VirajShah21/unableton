import SwiftUI
import UnabletonCore

struct ReferenceAudioSourceView: View {
    @ObservedObject var session: ProjectSession
    let derivation: ReferenceAudioDerivation
    var body: some View {
        InspectionValue("Source song", value: session.attachment(derivation.attachmentID)?.fileName ?? "Attached song")
        InspectionValue("Source range", value: "\(derivation.sourceStartSeconds.formatted())–\(derivation.sourceEndSeconds.formatted()) seconds")
        InspectionValue("Source stems", value: derivation.stemNames?.joined(separator: ", ") ?? derivation.stem)
        if let source = derivation.sourceTempo, let target = derivation.targetTempo {
            InspectionValue("Prepared tempo", value: "\(source.formatted()) → \(target.formatted()) BPM")
        }
        if let gain = derivation.mixGain { InspectionValue("Preparation gain", value: gain.formatted()) }
        Button("Play Original Song") { session.playAttachment(derivation.attachmentID) }
    }
}
