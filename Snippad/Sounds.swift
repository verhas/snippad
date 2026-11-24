import AppKit

/// The sounds Snippad can play when it puts something on the clipboard and
/// when it pastes: macOS's own alert sounds, chosen in the settings.
@MainActor
enum SnippadSound {
    /// The sounds in /System/Library/Sounds, by name.
    static let names: [String] = {
        let folder = URL(fileURLWithPath: "/System/Library/Sounds")
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { ["aiff", "aif", "caf", "wav"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent } ?? []
        return found.isEmpty
            ? ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
            : found.sorted()
    }()

    /// Something went on the clipboard; `own` when Snippad put it there.
    static func copied(own: Bool = true) {
        let s = SettingsStore.shared.value
        guard own || s.copySoundForOtherApps else { return }
        play(s.copySound)
    }

    static func pasted() {
        play(SettingsStore.shared.value.pasteSound)
    }

    static func play(_ name: String) {
        guard !name.isEmpty, !SnippadHome.isTesting else { return }
        // A new sound each time, so quick copies do not cut each other off.
        (NSSound(named: NSSound.Name(name))?.copy() as? NSSound)?.play()
    }
}
