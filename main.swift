import AppKit
import Foundation

// Shift-Command-4 → system writes Desktop file.
// We convert to clipboard-first UX: copy to pasteboard, remove Desktop file,
// show float. 复制/timeout = clipboard only; 存桌面 = write PNG.

final class OverlayController: NSObject {
    private var panel: NSPanel?
    private var imageView: NSImageView?
    private var currentImage: NSImage?
    private let desktopURL: URL

    private var watcher: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var knownFiles: Set<String> = []
    private var pendingNames: Set<String> = []
    private var retryWorkItems: [String: DispatchWorkItem] = [:]
    private var pollTimer: Timer?
    private var dismissTimer: Timer?
    private var ignorePasteboardUntil: Date?
    private let autoDismissSeconds: TimeInterval = 3.5

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
        // Skip files we ourselves saved via 存桌面
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

            // Clipboard-first: pasteboard first, then remove Desktop original
            self.writePasteboard(image)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                NSLog("remove screenshot failed: \(error)")
                // Still proceed — user at least has clipboard + float
            }

            self.pendingNames.remove(name)
            self.knownFiles.insert(name)
            self.retryWorkItems[name]?.cancel()
            self.retryWorkItems.removeValue(forKey: name)
            self.showOverlay(image: image)
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

    private func showOverlay(image: NSImage) {
        currentImage = image
        if panel == nil { buildPanel() }
        imageView?.image = image

        if let screen = NSScreen.main {
            let size = NSSize(width: 280, height: 220)
            let margin: CGFloat = 24
            let origin = NSPoint(
                x: screen.visibleFrame.maxX - size.width - margin,
                y: screen.visibleFrame.minY + margin
            )
            panel?.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        panel?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel?.orderFrontRegardless()
        panel?.makeKey()
        resetDismissTimer()
    }

    private func resetDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissSeconds, repeats: false) { [weak self] _ in
            // Timeout: clipboard only, no file
            self?.panel?.orderOut(nil)
        }
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)

        let chrome = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 280, height: 220))
        chrome.material = .hudWindow
        chrome.blendingMode = .behindWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 12
        chrome.layer?.masksToBounds = true
        chrome.autoresizingMask = [.width, .height]

        let imageView = NSImageView(frame: NSRect(x: 12, y: 52, width: 256, height: 156))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.autoresizingMask = [.width, .height]
        chrome.addSubview(imageView)
        self.imageView = imageView

        let copyBtn = NSButton(title: "复制", target: self, action: #selector(keepClipboard))
        copyBtn.frame = NSRect(x: 12, y: 12, width: 120, height: 28)
        copyBtn.bezelStyle = .rounded
        chrome.addSubview(copyBtn)

        let saveBtn = NSButton(title: "存桌面", target: self, action: #selector(saveToDesktop))
        saveBtn.frame = NSRect(x: 148, y: 12, width: 120, height: 28)
        saveBtn.bezelStyle = .rounded
        chrome.addSubview(saveBtn)

        panel.contentView = chrome
        self.panel = panel
    }

    @objc private func keepClipboard() {
        guard let image = currentImage else {
            panel?.orderOut(nil)
            return
        }
        writePasteboard(image)
        dismissTimer?.invalidate()
        panel?.orderOut(nil)
    }

    @objc private func saveToDesktop() {
        guard let image = currentImage else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        // Prefix 截屏浮窗 so watcher won't re-claim it
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
        dismissTimer?.invalidate()
        panel?.orderOut(nil)
    }

    private func writePasteboard(_ image: NSImage) {
        ignorePasteboardUntil = Date().addingTimeInterval(0.8)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }
}

let app = NSApplication.shared
let controller = OverlayController()
controller.start()
app.run()
