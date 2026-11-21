import AppKit

/// Adds edge/corner resizing to a borderless window while letting every other
/// click pass through to the SwiftUI content underneath.
final class WindowResizeOverlay: NSView {
    struct Edges: OptionSet {
        let rawValue: Int

        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top = Edges(rawValue: 1 << 3)

        var isCorner: Bool {
            let horizontal = contains(.left) || contains(.right)
            let vertical = contains(.bottom) || contains(.top)
            return horizontal && vertical
        }
    }

    private let margin: CGFloat = 10
    private var activeEdges: Edges = []
    private var initialFrame: NSRect = .zero
    private var initialMouseLocation: NSPoint = .zero

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return edges(at: local).isEmpty ? nil : self
    }

    private func edges(at point: NSPoint) -> Edges {
        guard bounds.width > margin, bounds.height > margin else { return [] }
        var edges: Edges = []
        if point.x <= margin { edges.insert(.left) }
        if point.x >= bounds.width - margin { edges.insert(.right) }
        if point.y <= margin { edges.insert(.bottom) }
        if point.y >= bounds.height - margin { edges.insert(.top) }
        return edges
    }

    // MARK: - Resizing

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        activeEdges = edges(at: point)
        guard !activeEdges.isEmpty else { return }
        initialFrame = window.frame
        initialMouseLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, !activeEdges.isEmpty else { return }

        let current = NSEvent.mouseLocation
        let deltaX = current.x - initialMouseLocation.x
        let deltaY = current.y - initialMouseLocation.y
        let minimum = minimumSize(for: window)

        var frame = initialFrame

        if activeEdges.contains(.left) {
            let width = max(minimum.width, initialFrame.width - deltaX)
            frame.origin.x = initialFrame.maxX - width
            frame.size.width = width
        } else if activeEdges.contains(.right) {
            frame.size.width = max(minimum.width, initialFrame.width + deltaX)
        }

        if activeEdges.contains(.bottom) {
            let height = max(minimum.height, initialFrame.height - deltaY)
            frame.origin.y = initialFrame.maxY - height
            frame.size.height = height
        } else if activeEdges.contains(.top) {
            frame.size.height = max(minimum.height, initialFrame.height + deltaY)
        }

        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges = []
    }

    private func minimumSize(for window: NSWindow) -> NSSize {
        let contentMinimum = window.contentMinSize
        return NSSize(
            width: max(320, contentMinimum.width),
            height: max(240, contentMinimum.height)
        )
    }

    // MARK: - Cursors

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        let width = bounds.width
        let height = bounds.height
        guard width > margin * 2, height > margin * 2 else { return }

        addCursorRect(
            NSRect(x: margin, y: 0, width: width - margin * 2, height: margin),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: margin, y: height - margin, width: width - margin * 2, height: margin),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: 0, y: margin, width: margin, height: height - margin * 2),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(x: width - margin, y: margin, width: margin, height: height - margin * 2),
            cursor: .resizeLeftRight
        )

        addCursorRect(
            NSRect(x: 0, y: 0, width: margin, height: margin),
            cursor: Self.frameResizeCursor(position: .bottomLeft)
        )
        addCursorRect(
            NSRect(x: width - margin, y: 0, width: margin, height: margin),
            cursor: Self.frameResizeCursor(position: .bottomRight)
        )
        addCursorRect(
            NSRect(x: 0, y: height - margin, width: margin, height: margin),
            cursor: Self.frameResizeCursor(position: .topLeft)
        )
        addCursorRect(
            NSRect(x: width - margin, y: height - margin, width: margin, height: margin),
            cursor: Self.frameResizeCursor(position: .topRight)
        )
    }

    private static func frameResizeCursor(position: NSCursor.FrameResizePosition) -> NSCursor {
        NSCursor.frameResize(position: position, directions: .all)
    }
}
