import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// NoteIntelligence runs Apple's on-device language model over a note: summaries and tag
/// suggestions that never leave the device. Everything is gated on the model actually
/// being present, so older systems and devices without Apple Intelligence simply do not
/// show the features.
enum NoteIntelligence {
    /// Whether the on-device model can run here right now.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return SystemLanguageModel.default.availability == .available
            }
            return false
        #else
            return false
        #endif
    }

    /// Summarizes a note body in a few sentences, on device.
    static func summarize(_ body: String) async throws -> String {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                let session = LanguageModelSession()
                let prompt = "Summarize the following note in three sentences or fewer. "
                    + "Plain prose, no preamble.\n\n" + String(body.prefix(6000))
                let response = try await session.respond(to: prompt)
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        #endif
        throw CocoaError(.featureUnsupported)
    }

    /// Suggests up to five tags for a note body, on device, lowercased and deduplicated
    /// against the tags it already carries.
    static func suggestTags(for body: String, existing: [String]) async throws -> [String] {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                let session = LanguageModelSession()
                let prompt = "Suggest up to five short tags for this note. Reply with only "
                    + "the tags, comma separated, lowercase, single words or "
                    + "slash/nested, no hash marks.\n\n" + String(body.prefix(6000))
                let response = try await session.respond(to: prompt)
                let existingKeys = Set(existing.map { $0.lowercased() })
                let tags = response.content
                    .split(separator: ",")
                    .map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "#."))
                            .lowercased()
                            .replacingOccurrences(of: " ", with: "-")
                    }
                    .filter { !$0.isEmpty && $0.count <= 30 && !existingKeys.contains($0) }
                return Array(tags.prefix(5))
            }
        #endif
        throw CocoaError(.featureUnsupported)
    }
}
