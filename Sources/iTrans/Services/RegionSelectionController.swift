import AppKit

@MainActor
final class RegionSelectionController {
    private var windows: [SelectionOverlayWindow] = []
    private var completion: ((CGRect?) -> Void)?
    private var keyMonitor: Any?
    private var didFinish = false

    /// Shows a full-screen selection overlay on every display and returns the
    /// selected rectangle in global screen coordinates (bottom-left origin).
    func select() async -> CGRect? {
        await withCheckedContinuation { continuation in
            self.completion = { rect in
                continuation.resume(returning: rect)
            }
            self.presentOverlays()
        }
    }

    private func presentOverlays() {
        NSApp.activate(ignoringOtherApps: true)

        for screen in NSScreen.screens {
            let window = SelectionOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.isMovable = false

            let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            view.onComplete = { [weak self, weak window] localRect in
                guard let self, let window else { return }
                let screenRect = window.convertToScreen(localRect)
                self.finish(with: screenRect)
            }
            view.onCancel = { [weak self] in
                self?.finish(with: nil)
            }

            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.finish(with: nil)
                return nil
            }
            return event
        }
    }

    private func finish(with rect: CGRect?) {
        guard !didFinish else { return }
        didFinish = true

        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        let completion = self.completion
        self.completion = nil
        completion?(rect)
    }
}

final class SelectionOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionOverlayView: NSView {
    var onComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection = selectionRect, selection.width >= 4, selection.height >= 4 else {
            onCancel?()
            return
        }
        onComplete?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private var selectionRect: NSRect? {
        guard let startPoint, let currentPoint else { return nil }
        return NSRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        context.fill(bounds)

        if let selection = selectionRect {
            context.setBlendMode(.clear)
            context.fill(selection)
            context.setBlendMode(.normal)

            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1.5
            border.stroke()

            drawSizeLabel(for: selection, in: context)
            drawRuleLines(at: NSPoint(x: selection.midX, y: selection.midY), in: context)
        } else {
            drawHint()
        }
    }

    private func drawSizeLabel(for selection: NSRect, in context: CGContext) {
        let label = "\(Int(selection.width)) × \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: label, attributes: attributes)
        let textSize = string.size()
        let padding = NSSize(width: 7, height: 4)

        var origin = NSPoint(
            x: selection.minX,
            y: selection.minY - textSize.height - padding.height * 2 - 6
        )
        if origin.y < 8 {
            origin.y = selection.minY + 6
        }
        if origin.x + textSize.width + padding.width * 2 > bounds.maxX - 8 {
            origin.x = bounds.maxX - textSize.width - padding.width * 2 - 8
        }

        let background = NSRect(
            x: origin.x,
            y: origin.y,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        let path = NSBezierPath(roundedRect: background, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()

        string.draw(at: NSPoint(x: origin.x + padding.width, y: origin.y + padding.height))
    }

    private func drawRuleLines(at point: NSPoint, in context: CGContext) {
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(0.5)
        context.beginPath()
        context.move(to: CGPoint(x: point.x, y: bounds.minY))
        context.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        context.move(to: CGPoint(x: bounds.minX, y: point.y))
        context.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
        context.strokePath()
    }

    private func drawHint() {
        let text = "拖拽选择需要识别的区域     ESC 取消"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: style
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let background = NSRect(
            x: (bounds.width - size.width) / 2 - 18,
            y: bounds.height - size.height - 110,
            width: size.width + 36,
            height: size.height + 16
        )
        let path = NSBezierPath(roundedRect: background, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.55).setFill()
        path.fill()
        string.draw(at: NSPoint(x: background.minX + 18, y: background.minY + 8))
    }
}
