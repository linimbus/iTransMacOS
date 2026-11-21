import AppKit
import ScreenCaptureKit

struct CapturedScreen {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let image: CGImage

    var scale: CGFloat {
        CGFloat(image.width) / max(frame.width, 1)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@MainActor
final class ScreenCaptureService {
    /// Captures every connected display before the selection overlay is shown.
    func captureAllScreens() async throws -> [CGDirectDisplayID: CapturedScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [CGDirectDisplayID: CapturedScreen] = [:]

        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                continue
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.showsCursor = false
            configuration.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            result[displayID] = CapturedScreen(
                displayID: displayID,
                frame: screen.frame,
                image: image
            )
        }

        return result
    }
}
