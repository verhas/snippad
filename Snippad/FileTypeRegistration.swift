import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Makes sure double-clicking a .snippad file in Finder opens it here.
///
/// Info.plist already declares the type and claims it with the Owner rank,
/// which LaunchServices honours once it has seen the app. That alone is not
/// always enough: another app may have been picked as the default in Finder's
/// "Open With", or LaunchServices may not have indexed this copy yet. So at
/// every launch the current default is checked and, if it is not Snippad,
/// this copy is registered and set as the default.
enum FileTypeRegistration {

    @MainActor
    static func claimSnippadFiles() {
        let workspace = NSWorkspace.shared
        let bundle = Bundle.main
        guard let ourID = bundle.bundleIdentifier else { return }

        // Compared by bundle identifier rather than path, so a debug build
        // started from DerivedData does not take the type away from the copy
        // in /Applications on every run.
        if let current = workspace.urlForApplication(toOpen: .snippad),
           Bundle(url: current)?.bundleIdentifier == ourID {
            return
        }

        LSRegisterURL(bundle.bundleURL as CFURL, true)
        workspace.setDefaultApplication(at: bundle.bundleURL, toOpen: .snippad) { error in
            if let error {
                NSLog("Snippad could not make itself the default app for .snippad files: %@",
                      error.localizedDescription)
            }
        }
    }
}
