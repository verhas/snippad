import AppKit

/// The question asked the first time something arrives from an iPhone, iPad
/// or another Mac through Universal Clipboard: what to call the one list all
/// such copies go to, or not to have one.
@MainActor
enum RemoteListPrompt {
    static func ask(_ answer: @escaping @MainActor (String?) -> Void) {
        // Not from inside the clipboard poll.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = "Something was copied on another device"
                alert.informativeText = """
                    It came through Universal Clipboard, from an iPhone, an iPad or another Mac. Snippad can keep everything copied on your other devices in a list of its own -- one single list for all of them, whichever device a copy comes from.

                    Name the list, or keep these copies with the rest. You can change this any time in Settings > General.
                    """
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
                field.stringValue = "iPhone & iPad"
                field.placeholderString = "iPhone & iPad"
                alert.accessoryView = field
                alert.addButton(withTitle: "Create List")
                alert.addButton(withTitle: "Keep With Other Copies")
                alert.window.initialFirstResponder = field
                NSApp.activate()
                let response = alert.runModal()
                answer(response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }
    }
}
