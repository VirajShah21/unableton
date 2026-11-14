import SwiftUI

/// Keep each read-only form row independently labeled for assistive technology.
struct InspectionValue: View {
    let name: String
    let value: String

    init(_ name: String, value: String) {
        self.name = name; self.value = value
    }

    var body: some View {
        LabeledContent(name, value: value)
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(value)
    }
}
