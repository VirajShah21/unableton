import Foundation
import Testing
@testable import Unableton

struct ReferencePrivacyPreferenceTests {
    @Test func oldCloudProcessingPreferenceDoesNotAuthorizeAudioUploads() throws {
        let name = "ReferencePrivacyTests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        #expect(!ReferencePrivacyPreferences.allowsAudioInspection(in: preferences))
        preferences.set(true, forKey: "references.enabled")
        #expect(!ReferencePrivacyPreferences.allowsAudioInspection(in: preferences))
        preferences.set(true, forKey: ReferencePrivacyPreferences.audioInspectionKey)
        #expect(ReferencePrivacyPreferences.allowsAudioInspection(in: preferences))
        preferences.set(false, forKey: ReferencePrivacyPreferences.audioInspectionKey)
        #expect(!ReferencePrivacyPreferences.allowsAudioInspection(in: preferences))
    }
}
