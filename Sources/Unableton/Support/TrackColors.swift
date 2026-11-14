import SwiftUI

enum TrackColors {
    static let palette: [Color] = [.indigo, .teal, .orange, .pink, .purple, .blue, .green, .yellow]
    static func color(_ index: Int) -> Color { palette[abs(index) % palette.count] }
    static func noteName(_ pitch: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[(pitch % 12 + 12) % 12])\(pitch / 12 - 1)"
    }
    static func position(_ beat: Double, beatsPerBar: Int = 4) -> String {
        let safe = max(0, beat)
        return "\(Int(safe) / beatsPerBar + 1).\(Int(safe) % beatsPerBar + 1).\(Int(safe.truncatingRemainder(dividingBy: 1) * 100))"
    }
}
