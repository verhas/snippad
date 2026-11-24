import AppKit
import ScreenCaptureKit

/// Take Screenshot: a whole screen (now, or after a delay counted down in
/// the menu bar), a window with or without its shadow, or an area. The
/// picture goes on the clipboard and into the screenshot list.
///
/// Screens are taken with ScreenCaptureKit; windows and areas with macOS's
/// own `screencapture`, which gives the camera pointer and the crosshair
/// people know. Both need the Screen Recording permission, which macOS asks
/// for the first time.
@MainActor
enum Screenshots {
    enum Mode {
        case window, windowWithShadow, area
    }

    /// The delays Settings offers, in seconds.
    static let delays = [10, 20, 30, 60]

    /// A screen to choose: its display id and a name ("Built-in Retina
    /// Display", "Sidecar Display").
    struct Screen {
        let id: CGDirectDisplayID
        let name: String
        let isMain: Bool
    }

    static var screens: [Screen] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Screen(id: CGDirectDisplayID(number.uint32Value), name: screen.localizedName, isMain: index == 0)
        }
    }

    private static var countdown: Task<Void, Never>?

    /// Waiting for a delayed screenshot.
    static var isCountingDown: Bool { countdown != nil }

    /// A whole screen, after `delay` seconds counted down in the menu bar.
    static func captureScreen(_ id: CGDirectDisplayID, delay: Int = 0) {
        countdown?.cancel()
        countdown = Task {
            if delay > 0 {
                for left in stride(from: delay, to: 0, by: -1) {
                    StatusMenu.shared.showCountdown(left)
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { StatusMenu.shared.showCountdown(nil); return }
                }
                StatusMenu.shared.showCountdown(nil)
            }
            countdown = nil
            // Let the menu close before the picture is taken.
            try? await Task.sleep(for: .milliseconds(250))
            do {
                let png = try await screenPNG(id)
                record(png, label: "Screenshot of \(screens.first { $0.id == id }?.name ?? "the screen")")
            } catch {
                report(error)
            }
        }
    }

    static func cancelCountdown() {
        countdown?.cancel()
        countdown = nil
        StatusMenu.shared.showCountdown(nil)
    }

    private static func screenPNG(_ id: CGDirectDisplayID) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw ClipboardError("That screen is no longer connected.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.backingScaleFactor ?? 2
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ClipboardError("The screenshot could not be made into a PNG.")
        }
        return png
    }

    /// A window (the pointer becomes a camera) or an area (a crosshair).
    /// Escape cancels, and then nothing happens.
    static func capture(_ mode: Mode) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("snippad-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        switch mode {
        case .window: process.arguments = ["-x", "-i", "-W", "-o", file.path]
        case .windowWithShadow: process.arguments = ["-x", "-i", "-W", file.path]
        case .area: process.arguments = ["-x", "-i", "-s", file.path]
        }
        let label = switch mode {
        case .window, .windowWithShadow: "Screenshot of a window"
        case .area: "Screenshot of an area"
        }
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    defer { try? FileManager.default.removeItem(at: file) }
                    // No file: the user pressed Escape.
                    guard let png = try? Data(contentsOf: file), !png.isEmpty else { return }
                    record(png, label: label)
                }
            }
        }
        do {
            try process.run()
        } catch {
            report(error)
        }
    }

    private static func record(_ png: Data, label: String) {
        ClipboardHistory.shared.addScreenshot(png, label: label)
    }

    private static func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "The screenshot could not be taken"
        alert.informativeText = error.localizedDescription
            + "\n\nSnippad needs the Screen Recording permission: System Settings › Privacy & Security › Screen & System Audio Recording."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}
