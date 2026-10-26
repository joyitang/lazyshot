import AppKit
import Foundation

// Shift-Command-4 → Desktop file → clipboard + delete original → Layer 1 float.
// 剪裁 / 画笔 → Layer 2 compact editor → 取消/保存 back to float.
// Share: 复制 / 存桌面 / 飞书 / 微信 on current float image.

// MARK: - Annotation model (image-space, bottom-left origin)

enum AnnoTool: Int {
    case crop = 0
    case rect = 1
    case arrow = 2
    case text = 3
}

enum Annotation: Equatable {
    case rect(NSRect)
    case arrow(from: NSPoint, to: NSPoint)
    case text(string: String, origin: NSPoint, fontSize: CGFloat)
}

// MARK: - Canvas

enum CropHandle: CaseIterable {
    case nw, n, ne, e, se, s, sw, w

    var cursor: NSCursor {
        switch self {
        case .n, .s: return .resizeUpDown
        case .e, .w: return .resizeLeftRight
        case .nw, .se: return .crosshair
        case .ne, .sw: return .crosshair
        }
    }
}

enum CanvasDrag {
    case none
    case createCrop
    case moveCrop(startMouse: NSPoint, startRect: NSRect)
    case resizeCrop(handle: CropHandle, startMouse: NSPoint, startRect: NSRect)
    case createAnno
    case moveAnno(index: Int, startMouse: NSPoint, original: Annotation)
    case resizeAnnoRect(index: Int, handle: CropHandle, startMouse: NSPoint, startRect: NSRect)
}

final class AnnotationCanvasView: NSView {
    var baseImage: NSImage? {
        didSet { needsDisplay = true }
    }
    var annotations: [Annotation] = [] {
        didSet { needsDisplay = true }
    }
    /// Crop region in image space; nil = full image (no crop applied on save).
    var cropRect: NSRect? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var tool: AnnoTool = .rect {
        didSet {
            if tool == .crop { ensureCropRect() }
            selectedAnnoIndex = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onEditingChanged: (() -> Void)?

    // MARK: Undo (edit-window only; cleared on reset / close)
    private struct EditSnapshot {
        let annotations: [Annotation]
        let cropRect: NSRect?
        let selectedAnnoIndex: Int?
    }
    private var undoStack: [EditSnapshot] = []
    /// Captured at mouseDown for a mutating gesture; pushed on mouseUp if state changed.
    private var undoBaseline: EditSnapshot?
    private let maxUndoLevels = 50

    private var drag: CanvasDrag = .none
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var textField: NSTextField?
    private var textFieldChrome: NSView?
    private var textImageOrigin: NSPoint?
    private var editingAnnoIndex: Int?
    private var editingFontSize: CGFloat = 28
    private var selectedAnnoIndex: Int? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private let strokeColor = NSColor.systemRed
    private let lineWidth: CGFloat = 3
    private let handleSize: CGFloat = 14
    private let hitSlop: CGFloat = 12

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    /// Critical: with borderless + movableByWindowBackground, default true steals
    /// annotation drags and moves the whole editor panel instead.
    override var mouseDownCanMoveWindow: Bool { false }

    func imageDrawRect() -> NSRect {
        guard let img = baseImage, img.size.width > 0, img.size.height > 0 else {
            return bounds
        }
        let iw = img.size.width
        let ih = img.size.height
        let scale = min(bounds.width / iw, bounds.height / ih)
        let w = iw * scale
        let h = ih * scale
        return NSRect(
            x: (bounds.width - w) / 2,
            y: (bounds.height - h) / 2,
            width: w,
            height: h
        )
    }

    func fullImageRect() -> NSRect {
        guard let img = baseImage else { return .zero }
        return NSRect(origin: .zero, size: img.size)
    }

    func ensureCropRect() {
        guard cropRect == nil, let img = baseImage, img.size.width > 0 else { return }
        // Start with full image so handles are immediately adjustable (native-like).
        cropRect = NSRect(origin: .zero, size: img.size)
    }

    func viewToImage(_ p: NSPoint, clamp: Bool = false) -> NSPoint? {
        guard let img = baseImage else { return nil }
        let r = imageDrawRect()
        guard r.width > 0, r.height > 0 else { return nil }
        if !clamp && !r.contains(p) { return nil }
        var x = (p.x - r.minX) / r.width * img.size.width
        var y = (p.y - r.minY) / r.height * img.size.height
        if clamp {
            x = min(max(x, 0), img.size.width)
            y = min(max(y, 0), img.size.height)
        }
        return NSPoint(x: x, y: y)
    }

    func imageToView(_ p: NSPoint) -> NSPoint {
        guard let img = baseImage else { return p }
        let r = imageDrawRect()
        return NSPoint(
            x: r.minX + p.x / img.size.width * r.width,
            y: r.minY + p.y / img.size.height * r.height
        )
    }

    func imageRectToView(_ ir: NSRect) -> NSRect {
        let o = imageToView(ir.origin)
        let tr = imageToView(NSPoint(x: ir.maxX, y: ir.maxY))
        return NSRect(x: o.x, y: o.y, width: tr.x - o.x, height: tr.y - o.y)
    }

    private func clampImageRect(_ r: NSRect) -> NSRect {
        let full = fullImageRect()
        var out = r
        out.size.width = max(8, out.size.width)
        out.size.height = max(8, out.size.height)
        out.origin.x = min(max(out.origin.x, full.minX), full.maxX - out.size.width)
        out.origin.y = min(max(out.origin.y, full.minY), full.maxY - out.size.height)
        out.size.width = min(out.size.width, full.maxX - out.origin.x)
        out.size.height = min(out.size.height, full.maxY - out.origin.y)
        return out
    }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        dirtyRect.fill()

        guard let img = baseImage else { return }
        let r = imageDrawRect()
        img.draw(in: r)

        // Annotations under crop chrome (hide the one currently being edited)
        for (i, a) in annotations.enumerated() {
            if i == editingAnnoIndex { continue }
            let selected = (i == selectedAnnoIndex)
            drawAnnotation(a, inViewSpace: true, selected: selected)
        }

        // Crop overlay (native-like dim + bright keep region + handles)
        if tool == .crop {
            if case .createCrop = drag, let s = dragStart, let c = dragCurrent,
               let is0 = viewToImage(s, clamp: true), let is1 = viewToImage(c, clamp: true) {
                let ir = NSRect(
                    x: min(is0.x, is1.x), y: min(is0.y, is1.y),
                    width: abs(is1.x - is0.x), height: abs(is1.y - is0.y)
                )
                drawCropOverlay(ir)
            } else if let existing = cropRect {
                drawCropOverlay(existing)
            } else {
                drawCropOverlay(fullImageRect())
            }
        }

        // Live create preview for markup tools
        if case .createAnno = drag, let s = dragStart, let c = dragCurrent {
            strokeColor.setStroke()
            strokeColor.setFill()
            switch tool {
            case .rect:
                let rect = NSRect(
                    x: min(s.x, c.x), y: min(s.y, c.y),
                    width: abs(c.x - s.x), height: abs(c.y - s.y)
                )
                let path = NSBezierPath(rect: rect)
                path.lineWidth = lineWidth
                path.stroke()
            case .arrow:
                drawArrowView(from: s, to: c)
            default:
                break
            }
        }
    }

    private func drawCropOverlay(_ ir: NSRect) {
        let vr = imageRectToView(ir)
        let full = imageDrawRect()

        // Strong dim outside keep-region (native screenshot feel)
        let dim = NSBezierPath(rect: bounds)
        let hole = NSBezierPath(rect: vr)
        dim.append(hole)
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.62).setFill()
        dim.fill()

        // Brighten keep region slightly with clear border
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(rect: vr).fill()

        // Solid white outer border (high contrast like native crop)
        let border = NSBezierPath(rect: vr)
        border.lineWidth = 2.5
        NSColor.white.setStroke()
        border.stroke()

        // Thin accent inset
        let inset = vr.insetBy(dx: 1, dy: 1)
        let accent = NSBezierPath(rect: inset)
        accent.lineWidth = 1
        NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
        accent.stroke()

        // Corner + edge handles
        for h in CropHandle.allCases {
            let hp = handlePoint(h, in: vr)
            let hs = handleSize
            let hr = NSRect(x: hp.x - hs / 2, y: hp.y - hs / 2, width: hs, height: hs)
            let path = NSBezierPath(roundedRect: hr, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()
            NSColor.systemBlue.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        _ = full
    }

    private func handlePoint(_ h: CropHandle, in r: NSRect) -> NSPoint {
        switch h {
        case .nw: return NSPoint(x: r.minX, y: r.maxY)
        case .n:  return NSPoint(x: r.midX, y: r.maxY)
        case .ne: return NSPoint(x: r.maxX, y: r.maxY)
        case .e:  return NSPoint(x: r.maxX, y: r.midY)
        case .se: return NSPoint(x: r.maxX, y: r.minY)
        case .s:  return NSPoint(x: r.midX, y: r.minY)
        case .sw: return NSPoint(x: r.minX, y: r.minY)
        case .w:  return NSPoint(x: r.minX, y: r.midY)
        }
    }

    private func hitCropHandle(at viewPt: NSPoint) -> CropHandle? {
        guard let cr = cropRect else { return nil }
        let vr = imageRectToView(cr)
        let slop = handleSize * 1.35
        for h in CropHandle.allCases {
            let hp = handlePoint(h, in: vr)
            if hypot(viewPt.x - hp.x, viewPt.y - hp.y) <= slop { return h }
        }
        return nil
    }

    private func drawAnnotation(_ a: Annotation, inViewSpace: Bool, selected: Bool) {
        switch a {
        case .rect(let ir):
            let r: NSRect = inViewSpace ? imageRectToView(ir) : ir
            let path = NSBezierPath(rect: r)
            path.lineWidth = inViewSpace ? lineWidth : max(2, lineWidth * scaleFactor())
            strokeColor.setStroke()
            path.stroke()
            if selected && inViewSpace {
                NSColor.systemYellow.withAlphaComponent(0.9).setStroke()
                let sel = NSBezierPath(rect: r.insetBy(dx: -2, dy: -2))
                sel.lineWidth = 1
                let dashes: [CGFloat] = [4, 3]
                sel.setLineDash(dashes, count: 2, phase: 0)
                sel.stroke()
                for h in [CropHandle.nw, .ne, .se, .sw] {
                    let hp = handlePoint(h, in: r)
                    let hs: CGFloat = 8
                    let hr = NSRect(x: hp.x - hs / 2, y: hp.y - hs / 2, width: hs, height: hs)
                    let hpPath = NSBezierPath(rect: hr)
                    NSColor.white.setFill()
                    hpPath.fill()
                    strokeColor.setStroke()
                    hpPath.lineWidth = 1
                    hpPath.stroke()
                }
            }
        case .arrow(let from, let to):
            if inViewSpace {
                strokeColor.setStroke()
                strokeColor.setFill()
                drawArrowView(from: imageToView(from), to: imageToView(to))
                if selected {
                    let a = imageToView(from)
                    let b = imageToView(to)
                    NSColor.systemYellow.setFill()
                    NSBezierPath(ovalIn: NSRect(x: a.x - 5, y: a.y - 5, width: 10, height: 10)).fill()
                    NSBezierPath(ovalIn: NSRect(x: b.x - 5, y: b.y - 5, width: 10, height: 10)).fill()
                }
            } else {
                strokeColor.setStroke()
                strokeColor.setFill()
                drawArrowImage(from: from, to: to, width: max(2, lineWidth * scaleFactor()))
            }
        case .text(let string, let origin, let fontSize):
            let font = NSFont.boldSystemFont(ofSize: inViewSpace ? fontSize * viewFontScale() : fontSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: strokeColor
            ]
            let pt = inViewSpace ? imageToView(origin) : origin
            (string as NSString).draw(at: pt, withAttributes: attrs)
            if selected && inViewSpace {
                let size = (string as NSString).size(withAttributes: attrs)
                let box = NSRect(x: pt.x - 2, y: pt.y - 2, width: size.width + 4, height: size.height + 4)
                NSColor.systemYellow.withAlphaComponent(0.9).setStroke()
                let sel = NSBezierPath(rect: box)
                sel.lineWidth = 1
                let dashes: [CGFloat] = [4, 3]
                sel.setLineDash(dashes, count: 2, phase: 0)
                sel.stroke()
            }
        }
    }

    private func scaleFactor() -> CGFloat {
        guard let img = baseImage else { return 1 }
        let r = imageDrawRect()
        return img.size.width / max(r.width, 1)
    }

    private func viewFontScale() -> CGFloat {
        guard let img = baseImage else { return 1 }
        let r = imageDrawRect()
        return r.width / max(img.size.width, 1)
    }

    private func drawArrowView(from: NSPoint, to: NSPoint) {
        drawArrowGeometry(from: from, to: to, width: lineWidth)
    }

    private func drawArrowImage(from: NSPoint, to: NSPoint, width: CGFloat) {
        drawArrowGeometry(from: from, to: to, width: width)
    }

    private func drawArrowGeometry(from: NSPoint, to: NSPoint, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = width
        path.lineCapStyle = .round
        path.stroke()

        let dx = to.x - from.x
        let dy = to.y - from.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len
        let uy = dy / len
        let head: CGFloat = max(10, width * 4)
        let left = NSPoint(
            x: to.x - ux * head - uy * head * 0.45,
            y: to.y - uy * head + ux * head * 0.45
        )
        let right = NSPoint(
            x: to.x - ux * head + uy * head * 0.45,
            y: to.y - uy * head - ux * head * 0.45
        )
        let headPath = NSBezierPath()
        headPath.move(to: to)
        headPath.line(to: left)
        headPath.line(to: right)
        headPath.close()
        headPath.fill()
    }

    // MARK: Hit-test annotations (topmost first)

    private func hitAnnotationIndex(at viewPt: NSPoint) -> Int? {
        for i in stride(from: annotations.count - 1, through: 0, by: -1) {
            if hitTestAnnotation(annotations[i], viewPt: viewPt, selected: i == selectedAnnoIndex) {
                return i
            }
        }
        return nil
    }

    private func hitTestAnnotation(_ a: Annotation, viewPt: NSPoint, selected: Bool) -> Bool {
        switch a {
        case .rect(let ir):
            let r = imageRectToView(ir)
            let outer = r.insetBy(dx: -hitSlop, dy: -hitSlop)
            guard outer.contains(viewPt) else { return false }
            // Selected: whole body movable. Unselected: border ring only so new draws aren't blocked.
            if selected { return true }
            let inset = max(hitSlop, lineWidth + 4)
            let inner = r.insetBy(dx: inset, dy: inset)
            if inner.width <= 2 || inner.height <= 2 { return true }
            return !inner.contains(viewPt)
        case .arrow(let from, let to):
            let a = imageToView(from)
            let b = imageToView(to)
            return distancePointToSegment(viewPt, a, b) <= hitSlop + lineWidth
        case .text(let string, let origin, let fontSize):
            let font = NSFont.boldSystemFont(ofSize: fontSize * viewFontScale())
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let size = (string as NSString).size(withAttributes: attrs)
            let pt = imageToView(origin)
            // Generous hit box: draw(at:) origin is near baseline; include ascent above + padding
            let box = NSRect(
                x: pt.x - 8,
                y: pt.y - 8,
                width: max(size.width + 16, 28),
                height: max(size.height + 16, 28)
            )
            return box.contains(viewPt)
        }
    }

    private func distancePointToSegment(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 < 1e-6 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = min(max(t, 0), 1)
        let proj = NSPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    private func hitAnnoRectHandle(index: Int, at viewPt: NSPoint) -> CropHandle? {
        guard case .rect(let ir) = annotations[index] else { return nil }
        let r = imageRectToView(ir)
        let slop = handleSize
        for h in [CropHandle.nw, .ne, .se, .sw] {
            let hp = handlePoint(h, in: r)
            if hypot(viewPt.x - hp.x, viewPt.y - hp.y) <= slop { return h }
        }
        return nil
    }

    private func resizedRect(start: NSRect, handle: CropHandle, deltaImage: NSPoint) -> NSRect {
        var minX = start.minX, maxX = start.maxX
        var minY = start.minY, maxY = start.maxY
        switch handle {
        case .nw:
            minX += deltaImage.x; maxY += deltaImage.y
        case .n:
            maxY += deltaImage.y
        case .ne:
            maxX += deltaImage.x; maxY += deltaImage.y
        case .e:
            maxX += deltaImage.x
        case .se:
            maxX += deltaImage.x; minY += deltaImage.y
        case .s:
            minY += deltaImage.y
        case .sw:
            minX += deltaImage.x; minY += deltaImage.y
        case .w:
            minX += deltaImage.x
        }
        if maxX - minX < 8 {
            if handle == .e || handle == .ne || handle == .se { maxX = minX + 8 }
            else { minX = maxX - 8 }
        }
        if maxY - minY < 8 {
            if handle == .n || handle == .ne || handle == .nw { maxY = minY + 8 }
            else { minY = maxY - 8 }
        }
        return clampImageRect(NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    private func translatedAnnotation(_ a: Annotation, delta: NSPoint) -> Annotation {
        switch a {
        case .rect(let r):
            return .rect(clampImageRect(r.offsetBy(dx: delta.x, dy: delta.y)))
        case .arrow(let from, let to):
            let full = fullImageRect()
            func clampP(_ p: NSPoint) -> NSPoint {
                NSPoint(x: min(max(p.x, full.minX), full.maxX),
                        y: min(max(p.y, full.minY), full.maxY))
            }
            return .arrow(from: clampP(NSPoint(x: from.x + delta.x, y: from.y + delta.y)),
                          to: clampP(NSPoint(x: to.x + delta.x, y: to.y + delta.y)))
        case .text(let s, let origin, let fontSize):
            let full = fullImageRect()
            let o = NSPoint(
                x: min(max(origin.x + delta.x, full.minX), full.maxX),
                y: min(max(origin.y + delta.y, full.minY), full.maxY)
            )
            return .text(string: s, origin: o, fontSize: fontSize)
        }
    }

    // MARK: Undo

    private func currentSnapshot() -> EditSnapshot {
        EditSnapshot(
            annotations: annotations,
            cropRect: cropRect,
            selectedAnnoIndex: selectedAnnoIndex
        )
    }

    private func beginUndoGroup() {
        undoBaseline = currentSnapshot()
    }

    private func endUndoGroup() {
        guard let before = undoBaseline else { return }
        undoBaseline = nil
        let after = currentSnapshot()
        guard before.annotations != after.annotations
                || before.cropRect != after.cropRect
                || before.selectedAnnoIndex != after.selectedAnnoIndex else {
            return
        }
        undoStack.append(before)
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst(undoStack.count - maxUndoLevels)
        }
    }

    private func pushUndoSnapshot(_ before: EditSnapshot) {
        let after = currentSnapshot()
        guard before.annotations != after.annotations
                || before.cropRect != after.cropRect
                || before.selectedAnnoIndex != after.selectedAnnoIndex else {
            return
        }
        undoStack.append(before)
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst(undoStack.count - maxUndoLevels)
        }
    }

    func clearUndoStack() {
        undoStack.removeAll()
        undoBaseline = nil
    }

    /// True while the on-canvas text field is up (typing / IME).
    var isEditingText: Bool { textField != nil }

    /// Pop one edit. Empty stack = no-op. Returns true if an undo ran or empty-stack no-op was handled.
    @discardableResult
    func undoLastEdit() -> Bool {
        // While typing, text field owns ⌘Z — callers should not reach here.
        if textField != nil { return false }
        guard let snap = undoStack.popLast() else { return true }
        annotations = snap.annotations
        cropRect = snap.cropRect
        selectedAnnoIndex = snap.selectedAnnoIndex
        drag = .none
        dragStart = nil
        dragCurrent = nil
        undoBaseline = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onEditingChanged?()
        return true
    }

    static func isCommandZ(_ event: NSEvent) -> Bool {
        // Plain ⌘Z only (ignore caps lock; no ⇧/⌥/⌃ → no redo)
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "z"
    }

    /// ⌘Z when canvas is first responder. While the text field / field editor is FR,
    /// AppKit delivers keys there instead — so typing & field-undo stay untouched.
    override func keyDown(with event: NSEvent) {
        if Self.isCommandZ(event) {
            _ = undoLastEdit()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitTextIfNeeded()
        let p = convert(event.locationInWindow, from: nil)
        onEditingChanged?()
        // Same as pre-undo: canvas takes FR first; beginTextEdit then moves FR to the field.
        window?.makeFirstResponder(self)

        if tool == .crop {
            ensureCropRect()
            guard imageDrawRect().contains(p) || cropRect != nil else { return }
            if let h = hitCropHandle(at: p), let cr = cropRect,
               let imgPt = viewToImage(p, clamp: true) {
                beginUndoGroup()
                drag = .resizeCrop(handle: h, startMouse: imgPt, startRect: cr)
                return
            }
            if let cr = cropRect {
                let vr = imageRectToView(cr)
                if vr.contains(p), let imgPt = viewToImage(p, clamp: true) {
                    beginUndoGroup()
                    drag = .moveCrop(startMouse: imgPt, startRect: cr)
                    return
                }
            }
            // Click outside existing crop → new selection
            beginUndoGroup()
            dragStart = p
            dragCurrent = p
            drag = .createCrop
            return
        }

        // Markup tools: hit existing first (move / resize / double-click edit text)
        if tool == .rect || tool == .arrow || tool == .text {
            if event.clickCount >= 2,
               let idx = hitAnnotationIndex(at: p),
               case .text(let string, let origin, let fontSize) = annotations[idx] {
                drag = .none
                selectedAnnoIndex = idx
                let viewPt = imageToView(origin)
                beginTextEdit(
                    atView: viewPt,
                    imageOrigin: origin,
                    initial: string,
                    editIndex: idx,
                    fontSize: fontSize
                )
                return
            }
            if let idx = selectedAnnoIndex,
               case .rect = annotations[idx],
               let h = hitAnnoRectHandle(index: idx, at: p),
               case .rect(let ir) = annotations[idx],
               let imgPt = viewToImage(p, clamp: true) {
                beginUndoGroup()
                drag = .resizeAnnoRect(index: idx, handle: h, startMouse: imgPt, startRect: ir)
                return
            }
            if let idx = hitAnnotationIndex(at: p), let imgPt = viewToImage(p, clamp: true) {
                selectedAnnoIndex = idx
                beginUndoGroup()
                drag = .moveAnno(index: idx, startMouse: imgPt, original: annotations[idx])
                needsDisplay = true
                return
            }
            selectedAnnoIndex = nil
        }

        switch tool {
        case .rect, .arrow:
            guard imageDrawRect().contains(p) else { return }
            beginUndoGroup()
            dragStart = p
            dragCurrent = p
            drag = .createAnno
        case .text:
            guard let imgPt = viewToImage(p) else { return }
            beginTextEdit(atView: p, imageOrigin: imgPt, initial: "", editIndex: nil, fontSize: 28)
        case .crop:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .createCrop, .createAnno:
            dragCurrent = p
            needsDisplay = true
        case .moveCrop(let startMouse, let startRect):
            guard let imgPt = viewToImage(p, clamp: true) else { return }
            let d = NSPoint(x: imgPt.x - startMouse.x, y: imgPt.y - startMouse.y)
            cropRect = clampImageRect(startRect.offsetBy(dx: d.x, dy: d.y))
        case .resizeCrop(let handle, let startMouse, let startRect):
            guard let imgPt = viewToImage(p, clamp: true) else { return }
            let d = NSPoint(x: imgPt.x - startMouse.x, y: imgPt.y - startMouse.y)
            cropRect = resizedRect(start: startRect, handle: handle, deltaImage: d)
        case .moveAnno(let index, let startMouse, let original):
            guard let imgPt = viewToImage(p, clamp: true) else { return }
            let d = NSPoint(x: imgPt.x - startMouse.x, y: imgPt.y - startMouse.y)
            guard annotations.indices.contains(index) else { return }
            annotations[index] = translatedAnnotation(original, delta: d)
        case .resizeAnnoRect(let index, let handle, let startMouse, let startRect):
            guard let imgPt = viewToImage(p, clamp: true) else { return }
            let d = NSPoint(x: imgPt.x - startMouse.x, y: imgPt.y - startMouse.y)
            guard annotations.indices.contains(index) else { return }
            annotations[index] = .rect(resizedRect(start: startRect, handle: handle, deltaImage: d))
        }
        onEditingChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer {
            endUndoGroup()
            drag = .none
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
        }

        switch drag {
        case .createCrop:
            guard let s = dragStart else { return }
            guard let is0 = viewToImage(s, clamp: true), let is1 = viewToImage(p, clamp: true) else { return }
            let rect = NSRect(
                x: min(is0.x, is1.x), y: min(is0.y, is1.y),
                width: abs(is1.x - is0.x), height: abs(is1.y - is0.y)
            )
            if rect.width > 8, rect.height > 8 {
                cropRect = clampImageRect(rect)
            }
        case .createAnno:
            guard let s = dragStart else { return }
            guard let is0 = viewToImage(s, clamp: true), let is1 = viewToImage(p, clamp: true) else { return }
            switch tool {
            case .rect:
                let rect = NSRect(
                    x: min(is0.x, is1.x), y: min(is0.y, is1.y),
                    width: abs(is1.x - is0.x), height: abs(is1.y - is0.y)
                )
                if rect.width > 4, rect.height > 4 {
                    annotations.append(.rect(rect))
                    selectedAnnoIndex = annotations.count - 1
                }
            case .arrow:
                if hypot(is1.x - is0.x, is1.y - is0.y) > 6 {
                    annotations.append(.arrow(from: is0, to: is1))
                    selectedAnnoIndex = annotations.count - 1
                }
            default:
                break
            }
        default:
            break
        }
        onEditingChanged?()
    }

    override func resetCursorRects() {
        discardCursorRects()
        if tool == .crop, let cr = cropRect {
            let vr = imageRectToView(cr)
            addCursorRect(vr.insetBy(dx: handleSize, dy: handleSize), cursor: .openHand)
            for h in CropHandle.allCases {
                let hp = handlePoint(h, in: vr)
                let hs = handleSize + 4
                let hr = NSRect(x: hp.x - hs / 2, y: hp.y - hs / 2, width: hs, height: hs)
                addCursorRect(hr, cursor: cursorForHandle(h))
            }
            return
        }
        if tool == .rect || tool == .arrow || tool == .text {
            addCursorRect(imageDrawRect(), cursor: .crosshair)
            if let idx = selectedAnnoIndex, annotations.indices.contains(idx) {
                switch annotations[idx] {
                case .rect(let ir):
                    let r = imageRectToView(ir)
                    addCursorRect(r, cursor: .openHand)
                    for h in [CropHandle.nw, .ne, .se, .sw] {
                        let hp = handlePoint(h, in: r)
                        let hs: CGFloat = 12
                        let hr = NSRect(x: hp.x - hs / 2, y: hp.y - hs / 2, width: hs, height: hs)
                        addCursorRect(hr, cursor: cursorForHandle(h))
                    }
                case .arrow(let from, let to):
                    let a = imageToView(from), b = imageToView(to)
                    let minX = min(a.x, b.x) - 8, maxX = max(a.x, b.x) + 8
                    let minY = min(a.y, b.y) - 8, maxY = max(a.y, b.y) + 8
                    addCursorRect(NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), cursor: .openHand)
                case .text(let string, let origin, let fontSize):
                    let font = NSFont.boldSystemFont(ofSize: fontSize * viewFontScale())
                    let size = (string as NSString).size(withAttributes: [.font: font])
                    let pt = imageToView(origin)
                    addCursorRect(NSRect(x: pt.x - 4, y: pt.y - 4, width: size.width + 8, height: size.height + 8), cursor: .openHand)
                }
            }
        }
    }

    private func cursorForHandle(_ h: CropHandle) -> NSCursor {
        switch h {
        case .n, .s: return .resizeUpDown
        case .e, .w: return .resizeLeftRight
        case .nw, .se, .ne, .sw: return .crosshair
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        // Prefer resetCursorRects; fall through
        super.cursorUpdate(with: event)
    }

    // MARK: Text

    private func beginTextEdit(
        atView viewPt: NSPoint,
        imageOrigin: NSPoint,
        initial: String,
        editIndex: Int?,
        fontSize: CGFloat
    ) {
        dismissTextFieldUI()
        textImageOrigin = imageOrigin
        editingAnnoIndex = editIndex
        editingFontSize = fontSize
        needsDisplay = true

        // Transparent on-image typing (native markup style — no card/chrome)
        let viewSize = max(14, fontSize * viewFontScale())
        let fieldH = ceil(viewSize * 1.35)
        let fieldW: CGFloat = max(160, min(bounds.width - 16, 420))
        var frame = NSRect(
            x: viewPt.x,
            y: viewPt.y - viewSize * 0.15,
            width: fieldW,
            height: fieldH
        )
        if frame.maxX > bounds.maxX - 4 {
            frame.origin.x = max(4, bounds.maxX - 4 - frame.width)
        }
        if frame.minX < 4 { frame.origin.x = 4 }
        if frame.maxY > bounds.maxY - 4 {
            frame.origin.y = max(4, bounds.maxY - 4 - frame.height)
        }
        if frame.minY < 4 { frame.origin.y = 4 }

        let tf = NSTextField(frame: frame)
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.backgroundColor = .clear
        tf.focusRingType = .none
        tf.font = NSFont.boldSystemFont(ofSize: viewSize)
        tf.textColor = strokeColor
        tf.placeholderAttributedString = NSAttributedString(
            string: "文字",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: viewSize),
                .foregroundColor: strokeColor.withAlphaComponent(0.35)
            ]
        )
        tf.stringValue = initial
        tf.cell?.sendsActionOnEndEditing = true
        if let cell = tf.cell as? NSTextFieldCell {
            cell.wraps = false
            cell.isScrollable = true
            cell.usesSingleLineMode = true
            cell.lineBreakMode = .byClipping
            cell.drawsBackground = false
        }
        tf.target = self
        tf.action = #selector(textFieldAction(_:))
        tf.delegate = self
        addSubview(tf)
        textFieldChrome = nil
        textField = tf
        window?.makeFirstResponder(tf)
        if let editor = tf.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.insertionPointColor = strokeColor
            editor.selectedTextAttributes = [
                .backgroundColor: strokeColor.withAlphaComponent(0.25),
                .foregroundColor: strokeColor
            ]
            if !initial.isEmpty {
                editor.selectAll(nil)
            }
        }
        onEditingChanged?()
    }

    @objc private func textFieldAction(_ sender: NSTextField) {
        commitTextIfNeeded()
    }

    private func dismissTextFieldUI() {
        textField?.removeFromSuperview()
        textFieldChrome?.removeFromSuperview()
        textField = nil
        textFieldChrome = nil
    }

    func commitTextIfNeeded() {
        guard let tf = textField else { return }
        let before = currentSnapshot()
        let s = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = textImageOrigin
        let editIdx = editingAnnoIndex
        let fontSize = editingFontSize
        dismissTextFieldUI()
        textImageOrigin = nil
        editingAnnoIndex = nil

        if !s.isEmpty, let origin {
            let anno = Annotation.text(string: s, origin: origin, fontSize: fontSize)
            if let editIdx, annotations.indices.contains(editIdx) {
                annotations[editIdx] = anno
                selectedAnnoIndex = editIdx
            } else {
                annotations.append(anno)
                selectedAnnoIndex = annotations.count - 1
            }
        } else if let editIdx, annotations.indices.contains(editIdx) {
            // Empty commit while editing existing → remove that text
            annotations.remove(at: editIdx)
            selectedAnnoIndex = nil
        }
        pushUndoSnapshot(before)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        window?.makeFirstResponder(self)
        onEditingChanged?()
    }

    func cancelTextEdit() {
        dismissTextFieldUI()
        textImageOrigin = nil
        editingAnnoIndex = nil
        needsDisplay = true
    }

    func resetEdits() {
        cancelTextEdit()
        annotations.removeAll()
        cropRect = nil
        selectedAnnoIndex = nil
        drag = .none
        clearUndoStack()
        needsDisplay = true
    }

    /// Composite annotations, then crop if cropRect is set (and not full image).
    func compositedImage() -> NSImage? {
        commitTextIfNeeded()
        guard let img = baseImage else { return nil }
        let size = img.size
        guard size.width > 0, size.height > 0 else { return img }

        let out = NSImage(size: size)
        out.lockFocus()
        img.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        strokeColor.setStroke()
        strokeColor.setFill()

        let stroke = max(2.5, min(size.width, size.height) / 200)

        for a in annotations {
            switch a {
            case .rect(let ir):
                let path = NSBezierPath(rect: ir)
                path.lineWidth = stroke
                path.stroke()
            case .arrow(let from, let to):
                drawArrowGeometry(from: from, to: to, width: stroke)
            case .text(let string, let origin, let fontSize):
                let font = NSFont.boldSystemFont(ofSize: fontSize)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: strokeColor
                ]
                (string as NSString).draw(at: origin, withAttributes: attrs)
            }
        }
        out.unlockFocus()

        guard let cr = cropRect, cr.width > 4, cr.height > 4 else { return out }
        let full = NSRect(origin: .zero, size: size)
        // Skip crop if essentially full frame
        if abs(cr.minX - full.minX) < 1, abs(cr.minY - full.minY) < 1,
           abs(cr.width - full.width) < 2, abs(cr.height - full.height) < 2 {
            return out
        }
        return cropImage(out, to: cr.integral)
    }

    private func cropImage(_ image: NSImage, to rect: NSRect) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cgFull = rep.cgImage else { return image }
        let pxW = CGFloat(cgFull.width)
        let pxH = CGFloat(cgFull.height)
        let sx = pxW / max(image.size.width, 1)
        let sy = pxH / max(image.size.height, 1)
        var pxRect = CGRect(
            x: rect.origin.x * sx,
            y: (image.size.height - rect.origin.y - rect.height) * sy,
            width: rect.width * sx,
            height: rect.height * sy
        )
        pxRect = pxRect.integral
        pxRect = pxRect.intersection(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        guard pxRect.width > 1, pxRect.height > 1,
              let cgCrop = cgFull.cropping(to: pxRect) else { return image }
        let outSize = NSSize(width: CGFloat(cgCrop.width) / sx,
                             height: CGFloat(cgCrop.height) / sy)
        return NSImage(cgImage: cgCrop, size: outSize)
    }
}

extension AnnotationCanvasView: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField,
              let editor = tf.currentEditor() as? NSTextView else { return }
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.insertionPointColor = strokeColor
        editor.selectedTextAttributes = [
            .backgroundColor: strokeColor.withAlphaComponent(0.25),
            .foregroundColor: strokeColor
        ]
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextIfNeeded()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEdit()
            return true
        }
        return false
    }
}

// MARK: - Keyable panels

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Empty toolbar / margin area: drag moves the borderless HUD; buttons on top still receive clicks.
final class ToolbarDragRegion: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Light-blue selection pill for tool buttons

final class ToolPillButton: NSButton {
    private var baseTitle: String = ""

    var isToolSelected: Bool = false {
        didSet { applySelectedStyle() }
    }

    override var title: String {
        get { baseTitle.isEmpty ? super.title : baseTitle }
        set {
            baseTitle = newValue
            applySelectedStyle()
        }
    }

    private func applySelectedStyle() {
        let label = baseTitle.isEmpty ? super.title : baseTitle
        if baseTitle.isEmpty { baseTitle = super.title }
        if isToolSelected {
            attributedTitle = NSAttributedString(string: label, attributes: [
                .foregroundColor: NSColor.systemBlue,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ])
        } else {
            attributedTitle = NSAttributedString(string: label, attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ])
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isToolSelected {
            let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1.5), xRadius: 8, yRadius: 8)
            NSColor.systemBlue.withAlphaComponent(0.34).setFill()
            pill.fill()
            NSColor.systemBlue.withAlphaComponent(0.55).setStroke()
            pill.lineWidth = 1
            pill.stroke()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - Controller

final class OverlayController: NSObject {
    // Layer 1 — bottom-right float
    private var floatPanel: KeyablePanel?
    private var thumbView: NSImageView?
    private var floatChrome: NSView?

    // Layer 2 — compact editor
    private var editorPanel: KeyablePanel?
    private var canvas: AnnotationCanvasView?
    private var toolButtons: [ToolPillButton] = []
    private var editorChrome: NSView?
    private var toolbarDragRegion: ToolbarDragRegion?
    private var saveButton: NSButton?

    /// Image currently shown in the float (original or last saved edit).
    private var floatImage: NSImage?
    /// Snapshot when editor opened (for 取消).
    private var editorBaseImage: NSImage?

    private let desktopURL: URL

    private var watcher: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var knownFiles: Set<String> = []
    private var pendingNames: Set<String> = []
    private var retryWorkItems: [String: DispatchWorkItem] = [:]
    private var pollTimer: Timer?
    private var dismissTimer: Timer?
    private var ignorePasteboardUntil: Date?
    /// More reliable than NSPanel.isVisible for accessory panels.
    private var isEditorOpen = false

    /// Float auto-dismiss; paused while editor is open.
    private let idleDismissSeconds: TimeInterval = 6

    private let feishuBundleIDs = ["com.electron.lark", "com.larksuite.lark", "com.bytedance.macos.feishu"]
    private let wechatBundleIDs = ["com.tencent.xinWeChat"]

    // Float layout constants
    private let floatW: CGFloat = 148
    private let floatH: CGFloat = 236
    private let floatMargin: CGFloat = 16

    override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.desktopURL = home.appendingPathComponent("Desktop")
        super.init()
    }

    func start() {
        seedKnownFiles()
        startWatching()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.scanForNewScreenshot()
        }
        NSApp.setActivationPolicy(.accessory)
    }

    private func seedKnownFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: desktopURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in files where isScreenshot(url) {
            knownFiles.insert(url.lastPathComponent)
        }
    }

    private func isScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return false }
        if name.hasPrefix("截屏浮窗") { return false }
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(ext) else { return false }
        return name.hasPrefix("截屏")
            || name.hasPrefix("Screenshot")
            || name.hasPrefix("Screen Shot")
    }

    private func startWatching() {
        dirFD = open(desktopURL.path, O_EVTONLY)
        guard dirFD >= 0 else {
            NSLog("Cannot open Desktop for watching")
            return
        }
        let mask: DispatchSource.FileSystemEvent = [
            .write, .extend, .attrib, .link, .rename, .delete
        ]
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: mask,
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.scanForNewScreenshot()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
        }
        watcher = source
        source.resume()
    }

    private func scanForNewScreenshot() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: desktopURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var newest: (URL, Date)?
        for url in files where isScreenshot(url) {
            let name = url.lastPathComponent
            if knownFiles.contains(name) || pendingNames.contains(name) { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            if Date().timeIntervalSince(date) > 20 {
                knownFiles.insert(name)
                continue
            }
            if size < 64 { continue }
            if newest == nil || date > newest!.1 {
                newest = (url, date)
            }
        }
        if let (url, _) = newest {
            tryClaim(url: url, attempt: 0)
        }
    }

    private func tryClaim(url: URL, attempt: Int) {
        let name = url.lastPathComponent
        if knownFiles.contains(name) { return }

        let size1 = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size1 < 64 {
            scheduleRetry(url: url, attempt: attempt)
            return
        }

        pendingNames.insert(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let size2 = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size2 != size1 || size2 < 64 {
                self.pendingNames.remove(name)
                self.scheduleRetry(url: url, attempt: attempt)
                return
            }
            guard let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else {
                self.pendingNames.remove(name)
                self.scheduleRetry(url: url, attempt: attempt)
                return
            }

            self.writePasteboard(image)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                NSLog("remove screenshot failed: \(error)")
            }

            self.pendingNames.remove(name)
            self.knownFiles.insert(name)
            self.retryWorkItems[name]?.cancel()
            self.retryWorkItems.removeValue(forKey: name)
            self.showFloat(image: image)
        }
    }

    private func scheduleRetry(url: URL, attempt: Int) {
        let name = url.lastPathComponent
        guard attempt < 12 else {
            knownFiles.insert(name)
            pendingNames.remove(name)
            return
        }
        retryWorkItems[name]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.tryClaim(url: url, attempt: attempt + 1)
        }
        retryWorkItems[name] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: Layer 1 — bottom-right float

    private func showFloat(image: NSImage) {
        // Close editor if open (new capture wins)
        hideEditor(restoreFloat: false)
        floatImage = image
        if floatPanel == nil { buildFloatPanel() }
        thumbView?.image = image
        positionFloatBottomRight()
        floatPanel?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        floatPanel?.orderFrontRegardless()
        resetIdleDismissTimer()
    }

    private func refreshFloatImage(_ image: NSImage) {
        floatImage = image
        thumbView?.image = image
        writePasteboard(image)
        if floatPanel == nil { buildFloatPanel() }
        positionFloatBottomRight()
        floatPanel?.orderFrontRegardless()
        resetIdleDismissTimer()
    }

    private func positionFloatBottomRight() {
        guard let screen = NSScreen.main, let panel = floatPanel else { return }
        let vis = screen.visibleFrame
        let origin = NSPoint(
            x: vis.maxX - floatW - floatMargin,
            y: vis.minY + floatMargin
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: floatW, height: floatH)), display: true)
    }

    private func buildFloatPanel() {
        let w = floatW
        let h = floatH
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        panel.becomesKeyOnlyIfNeeded = true

        let chrome = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        chrome.material = .hudWindow
        chrome.blendingMode = .behindWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 14
        chrome.layer?.masksToBounds = true
        chrome.autoresizingMask = [.width, .height]

        let pad: CGFloat = 10
        let iconRowH: CGFloat = 52
        let shareH: CGFloat = 72
        let gap: CGFloat = 6

        // Top: 剪裁 + 画笔
        let cropBtn = makeFloatIconButton(title: "剪裁", symbol: "crop", action: #selector(openEditorCrop))
        let brushBtn = makeFloatIconButton(title: "画笔", symbol: "pencil.tip", action: #selector(openEditorBrush))
        let half = (w - pad * 2 - gap) / 2
        cropBtn.frame = NSRect(x: pad, y: h - pad - iconRowH, width: half, height: iconRowH)
        brushBtn.frame = NSRect(x: pad + half + gap, y: h - pad - iconRowH, width: half, height: iconRowH)
        chrome.addSubview(cropBtn)
        chrome.addSubview(brushBtn)

        // Thumbnail
        let thumbY = pad + shareH + gap
        let thumbH = h - pad - iconRowH - gap - thumbY
        let thumb = NSImageView(frame: NSRect(x: pad, y: thumbY, width: w - pad * 2, height: max(thumbH, 40)))
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        chrome.addSubview(thumb)
        self.thumbView = thumb

        // Bottom 2×2: 复制 / 存桌面 / 飞书 / 微信
        let shares: [(String, String, Selector)] = [
            ("复制", "doc.on.doc", #selector(keepClipboard)),
            ("存桌面", "desktopcomputer", #selector(saveToDesktop)),
            ("飞书", "paperplane", #selector(shareFeishu)),
            ("微信", "message", #selector(shareWechat))
        ]
        let cellW = (w - pad * 2 - gap) / 2
        let cellH = (shareH - gap) / 2
        for (i, item) in shares.enumerated() {
            let col = i % 2
            let row = i / 2 // 0 = top of share grid (复制/存桌面), closer to thumb
            // AppKit Y grows up: row0 at higher Y
            let y = pad + CGFloat(1 - row) * (cellH + gap)
            let x = pad + CGFloat(col) * (cellW + gap)
            let b = makeFloatIconButton(title: item.0, symbol: item.1, action: item.2)
            b.frame = NSRect(x: x, y: y, width: cellW, height: cellH)
            chrome.addSubview(b)
        }

        panel.contentView = chrome
        self.floatChrome = chrome
        self.floatPanel = panel
    }

    private func makeFloatIconButton(title: String, symbol: String, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .recessed
        b.isBordered = false
        b.setButtonType(.momentaryChange)
        b.wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let imgView = NSImageView()
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            imgView.image = img.withSymbolConfiguration(cfg)
        }
        imgView.contentTintColor = .labelColor
        imgView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(imgView)
        stack.addArrangedSubview(label)
        b.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: b.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            imgView.widthAnchor.constraint(equalToConstant: 20),
            imgView.heightAnchor.constraint(equalToConstant: 18)
        ])
        return b
    }

    private func resetIdleDismissTimer() {
        dismissTimer?.invalidate()
        // Don't auto-dismiss while editor is open
        if isEditorOpen { return }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: idleDismissSeconds, repeats: false) { [weak self] _ in
            guard let self, !self.isEditorOpen else { return }
            // Timeout = clipboard only (already written on capture / save)
            self.hideFloat()
        }
    }

    private func hideFloat() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        floatPanel?.orderOut(nil)
    }

    // MARK: Layer 2 — compact editor

    @objc private func openEditorCrop() {
        openEditor(initialTool: .crop)
    }

    @objc private func openEditorBrush() {
        openEditor(initialTool: .rect)
    }

    private func openEditor(initialTool: AnnoTool) {
        guard let image = floatImage else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil
        isEditorOpen = true
        editorBaseImage = image

        if editorPanel == nil { buildEditorPanel() }

        canvas?.baseImage = image
        canvas?.resetEdits()
        canvas?.tool = initialTool
        selectToolButton(tag: initialTool.rawValue)

        layoutEditorForImage(image)
        // Hide float while editing
        floatPanel?.orderOut(nil)

        editorPanel?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        editorPanel?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        editorPanel?.orderFrontRegardless()
        editorPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let canvas { canvas.window?.invalidateCursorRects(for: canvas) }
    }

    private func layoutEditorForImage(_ image: NSImage) {
        guard let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        let chromeH: CGFloat = 52 // single toolbar row
        // Usable annotate size: ~60–70% of visible screen (not tiny, not fullscreen)
        let maxW = min(vis.width * 0.70, vis.width - 60)
        let maxH = min(vis.height * 0.68, vis.height - 60) - chromeH
        let iw = max(image.size.width, 1)
        let ih = max(image.size.height, 1)
        // Fit image into that box; allow modest upscale for small captures so tools stay precise
        let fit = min(maxW / iw, maxH / ih)
        let scale = min(max(fit, 0.35), 1.25)
        let canvasW = min(maxW, max(420, iw * scale))
        let canvasH = min(maxH, max(280, ih * scale))
        let panelW = canvasW + 20
        let panelH = canvasH + chromeH + 10

        editorPanel?.setFrame(
            NSRect(
                x: vis.midX - panelW / 2,
                y: vis.midY - panelH / 2,
                width: panelW,
                height: panelH
            ),
            display: false
        )
        editorPanel?.setContentSize(NSSize(width: panelW, height: panelH))
        if let panel = editorPanel {
            var f = panel.frame
            f.origin = NSPoint(x: vis.midX - f.width / 2, y: vis.midY - f.height / 2)
            panel.setFrame(f, display: true)
        }
        layoutEditorChrome(panelW: panelW, panelH: panelH, canvasH: canvasH)
    }

    private func layoutEditorChrome(panelW: CGFloat, panelH: CGFloat, canvasH: CGFloat) {
        let side: CGFloat = 10
        let toolH: CGFloat = 32
        let toolY = panelH - side - toolH
        let toolbarBandH: CGFloat = side + toolH + side

        canvas?.frame = NSRect(
            x: side,
            y: side,
            width: panelW - side * 2,
            height: canvasH
        )

        // Full-width toolbar band behind buttons — only this moves the window
        if let drag = toolbarDragRegion {
            drag.frame = NSRect(x: 0, y: panelH - toolbarBandH, width: panelW, height: toolbarBandH)
            if let chrome = editorChrome {
                chrome.addSubview(drag, positioned: .below, relativeTo: toolButtons.first)
            }
        }

        // Tools left-aligned; 取消/保存 right-aligned (above drag region)
        let tools = toolButtons
        var x: CGFloat = side
        let toolW: CGFloat = 52
        let gap: CGFloat = 4
        for b in tools {
            b.frame = NSRect(x: x, y: toolY, width: toolW, height: toolH)
            x += toolW + gap
            editorChrome?.addSubview(b) // keep above drag region
        }

        let cancelW: CGFloat = 56
        let saveW: CGFloat = 64
        if let cancel = editorChrome?.viewWithTag(9001) {
            cancel.frame = NSRect(x: panelW - side - saveW - gap - cancelW, y: toolY, width: cancelW, height: toolH)
            editorChrome?.addSubview(cancel)
        }
        if let save = saveButton {
            save.frame = NSRect(x: panelW - side - saveW, y: toolY, width: saveW, height: toolH)
            editorChrome?.addSubview(save)
        }
    }

    private func buildEditorPanel() {
        let w: CGFloat = 480
        let h: CGFloat = 360
        // Borderless HUD — no titled white 「截屏编辑」 header (native markup feel)
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        // Do NOT move window from canvas; toolbar strip handles drag (see ToolbarDragRegion).
        panel.isMovableByWindowBackground = false

        let chrome = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        chrome.material = .hudWindow
        chrome.blendingMode = .behindWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 14
        chrome.layer?.masksToBounds = true
        chrome.autoresizingMask = [.width, .height]

        let canvas = AnnotationCanvasView(frame: NSRect(x: 10, y: 10, width: w - 20, height: 280))
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 8
        canvas.layer?.masksToBounds = true
        canvas.onEditingChanged = { [weak self] in
            self?.dismissTimer?.invalidate()
        }
        chrome.addSubview(canvas)
        self.canvas = canvas

        let dragRegion = ToolbarDragRegion(frame: NSRect(x: 0, y: h - 52, width: w, height: 52))
        dragRegion.autoresizingMask = [.width, .minYMargin]
        chrome.addSubview(dragRegion)
        self.toolbarDragRegion = dragRegion

        toolButtons = []
        let tools: [(String, AnnoTool)] = [
            ("剪裁", .crop),
            ("红框", .rect),
            ("箭头", .arrow),
            ("文字", .text)
        ]
        for (title, t) in tools {
            let b = ToolPillButton(title: title, target: self, action: #selector(selectTool(_:)))
            b.tag = t.rawValue
            b.bezelStyle = .recessed
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            chrome.addSubview(b)
            toolButtons.append(b)
        }

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancelEditor))
        cancelBtn.bezelStyle = .recessed
        cancelBtn.setButtonType(.momentaryPushIn)
        cancelBtn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        cancelBtn.tag = 9001
        chrome.addSubview(cancelBtn)

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveEditor))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        saveBtn.bezelColor = .controlAccentColor
        chrome.addSubview(saveBtn)
        self.saveButton = saveBtn

        // Tools/actions above drag region so they still receive clicks
        for b in toolButtons { chrome.addSubview(b) }  // already added; ensure z-order
        if let cancel = chrome.viewWithTag(9001) { chrome.addSubview(cancel) }
        if let save = saveButton { chrome.addSubview(save) }

        panel.contentView = chrome
        panel.delegate = self
        self.editorChrome = chrome
        self.editorPanel = panel

        layoutEditorChrome(panelW: w, panelH: h, canvasH: 280)
        selectToolButton(tag: AnnoTool.rect.rawValue)
    }

    @objc private func selectTool(_ sender: NSButton) {
        canvas?.commitTextIfNeeded()
        if let t = AnnoTool(rawValue: sender.tag) {
            canvas?.tool = t
        }
        selectToolButton(tag: sender.tag)
    }

    private func selectToolButton(tag: Int) {
        for b in toolButtons {
            b.isToolSelected = (b.tag == tag)
            b.needsDisplay = true
        }
    }

    @objc private func cancelEditor() {
        // Discard edits → float keeps original
        hideEditor(restoreFloat: true)
        if let img = editorBaseImage ?? floatImage {
            floatImage = img
            thumbView?.image = img
        }
        resetIdleDismissTimer()
    }

    @objc private func saveEditor() {
        guard let result = canvas?.compositedImage() else {
            cancelEditor()
            return
        }
        canvas?.resetEdits()
        hideEditor(restoreFloat: true)
        refreshFloatImage(result)
    }

    private func hideEditor(restoreFloat: Bool) {
        canvas?.cancelTextEdit()
        canvas?.clearUndoStack()
        isEditorOpen = false
        editorPanel?.orderOut(nil)
        if restoreFloat, floatImage != nil {
            positionFloatBottomRight()
            floatPanel?.orderFrontRegardless()
        }
    }

    // MARK: Share actions (operate on float image)

    @objc private func keepClipboard() {
        guard let image = floatImage else {
            hideFloat()
            return
        }
        writePasteboard(image)
        hideFloat()
    }

    @objc private func saveToDesktop() {
        guard let image = floatImage else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "截屏浮窗 \(formatter.string(from: Date())).png"
        let dest = desktopURL.appendingPathComponent(name)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: dest)
            knownFiles.insert(name)
        } catch {
            NSLog("save failed: \(error)")
            return
        }
        writePasteboard(image)
        hideFloat()
    }

    @objc private func shareFeishu() {
        share(toBundleIDs: feishuBundleIDs, label: "飞书")
    }

    @objc private func shareWechat() {
        share(toBundleIDs: wechatBundleIDs, label: "微信")
    }

    private func share(toBundleIDs ids: [String], label: String) {
        guard let image = floatImage else { return }
        writePasteboard(image)
        hideFloat()

        let ok = activateApp(bundleIDs: ids)
        if !ok {
            NSLog("share: could not open \(label)")
        }
    }

    private func activateApp(bundleIDs: [String]) -> Bool {
        let ws = NSWorkspace.shared
        for id in bundleIDs {
            if let urls = ws.urlForApplication(withBundleIdentifier: id) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                ws.openApplication(at: urls, configuration: config) { _, error in
                    if let error { NSLog("open \(id) failed: \(error)") }
                }
                return true
            }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            if let app = running.first {
                app.activate()
                return true
            }
        }
        return false
    }

    private func writePasteboard(_ image: NSImage) {
        ignorePasteboardUntil = Date().addingTimeInterval(0.8)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }
}

extension OverlayController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Treat as cancel if editor closed somehow
        if notification.object as AnyObject? === editorPanel {
            canvas?.clearUndoStack()
            isEditorOpen = false
            if let img = editorBaseImage ?? floatImage {
                floatImage = img
                thumbView?.image = img
            }
            positionFloatBottomRight()
            floatPanel?.orderFrontRegardless()
            resetIdleDismissTimer()
        }
    }
}

let app = NSApplication.shared
let controller = OverlayController()
controller.start()
app.run()
