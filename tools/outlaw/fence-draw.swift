// fence-draw.swift — draw Clawd's roam fence with the mouse.
//
// Launches a full-screen translucent overlay on the screen under the cursor.
// Drag a rectangle; on release the selection is written to
// ~/.clawd/roam-area.json as work-area fractions (the roam-fence format,
// see docs/guides/roam-fence.md) and the app exits. Press Esc to cancel.
// The running Clawd picks the change up within one roam pause (~4–8s).
//
// Build:  swiftc -O fence-draw.swift -o clawd-fence-draw
// Run:    ./clawd-fence-draw

import AppKit

final class SelectionView: NSView {
    var dragStart: NSPoint?
    var dragRect: NSRect = .zero
    var onDone: ((NSRect?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) } // Esc
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragRect = NSRect(
            x: min(start.x, p.x),
            y: min(start.y, p.y),
            width: abs(p.x - start.x),
            height: abs(p.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Ignore stray clicks; a fence needs real area.
        if dragRect.width < 10 || dragRect.height < 10 {
            dragStart = nil
            dragRect = .zero
            needsDisplay = true
            return
        }
        onDone?(dragRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0, alpha: 0.35).setFill()
        bounds.fill()
        guard dragRect.width > 0 else {
            drawHint()
            return
        }
        // Punch the selection clear so the fenced area shows through.
        NSColor.clear.setFill()
        dragRect.fill(using: .copy)
        NSColor.systemOrange.setStroke()
        let outline = NSBezierPath(rect: dragRect)
        outline.lineWidth = 2
        outline.stroke()
        let label = String(
            format: "%.0f × %.0f — release to set fence",
            dragRect.width, dragRect.height
        )
        drawText(label, at: NSPoint(x: dragRect.minX, y: dragRect.maxY + 8))
    }

    private func drawHint() {
        drawText(
            "Drag Clawd's roam fence — Esc to cancel",
            at: NSPoint(x: bounds.midX - 160, y: bounds.midY)
        )
    }

    private func drawText(_ s: String, at p: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
        ]
        NSAttributedString(string: s, attributes: attrs).draw(at: p)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main!
        // The fence is expressed in fractions of the WORK AREA (menu bar and
        // Dock excluded) — same rectangle Clawd's roam picker uses.
        let work = screen.visibleFrame

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onDone = { [weak self] rect in
            defer { NSApp.terminate(nil) }
            guard let rect = rect, let self = self else { return }
            // View/window coords share the screen's origin (window covers the
            // full screen frame). Convert to global, then to work-area
            // fractions with a top-left convention (top = distance from the
            // work area's top edge), matching the roam-fence file format.
            let globalRect = NSRect(
                x: rect.minX + screen.frame.minX,
                y: rect.minY + screen.frame.minY,
                width: rect.width,
                height: rect.height
            )
            let clamped = globalRect.intersection(work)
            guard clamped.width > 0, clamped.height > 0 else { return }
            let left = (clamped.minX - work.minX) / work.width
            let right = (clamped.maxX - work.minX) / work.width
            let top = (work.maxY - clamped.maxY) / work.height
            let bottom = (work.maxY - clamped.minY) / work.height
            self.writeFence(left: left, top: top, right: right, bottom: bottom)
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
    }

    func writeFence(left: Double, top: Double, right: Double, bottom: Double) {
        // Hand-formatted JSON: %.4f keeps the user-facing file readable
        // (JSONSerialization would emit 0.86650000000000005-style doubles).
        let json = String(
            format: "{\"enabled\": true, \"left\": %.4f, \"top\": %.4f, \"right\": %.4f, \"bottom\": %.4f}",
            max(0, left), max(0, top), min(1, right), min(1, bottom)
        )
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawd")
        let path = dir.appendingPathComponent("roam-area.json")
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            // Atomic: rename-based save; the loader's isolated-ENOENT
            // tolerance covers the replace window.
            try json.data(using: .utf8)!.write(to: path, options: .atomic)
            FileHandle.standardOutput.write(
                ("fence set: " + json + "\n").data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write(
                "fence-draw: write failed: \(error)\n".data(using: .utf8)!)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// --test-rect x,y,w,h: headless check of the geometry + write path. The rect
// is interpreted in the main screen's global coordinates (bottom-left origin,
// like NSScreen). No overlay is shown; the fence file is written and the
// computed work area + fractions are printed. Lets CI (and cautious
// assistants) verify everything except the literal mouse drag.
if let idx = CommandLine.arguments.firstIndex(of: "--test-rect"),
   idx + 1 < CommandLine.arguments.count {
    let parts = CommandLine.arguments[idx + 1].split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4, let screen = NSScreen.main else {
        FileHandle.standardError.write("fence-draw: bad --test-rect\n".data(using: .utf8)!)
        exit(2)
    }
    let rect = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    let work = screen.visibleFrame
    let clamped = rect.intersection(work)
    guard clamped.width > 0, clamped.height > 0 else {
        FileHandle.standardError.write("fence-draw: rect outside work area\n".data(using: .utf8)!)
        exit(3)
    }
    print("work-area: \(work)")
    let delegate = AppDelegate()
    delegate.writeFence(
        left: (clamped.minX - work.minX) / work.width,
        top: (work.maxY - clamped.maxY) / work.height,
        right: (clamped.maxX - work.minX) / work.width,
        bottom: (work.maxY - clamped.minY) / work.height
    )
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar takeover
let delegate = AppDelegate()
app.delegate = delegate
app.run()
