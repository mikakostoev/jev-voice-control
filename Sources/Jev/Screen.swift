import ScreenCaptureKit
import Vision

/// Fallback for apps that expose nothing through Accessibility (Telegram, games, custom-drawn UIs):
/// screenshot the app's window, OCR it, and treat every line of text as a click target.
enum Screen {
    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system "Screen Recording" prompt (once per app signature).
    static func requestAccess() { CGRequestScreenCaptureAccess() }

    static func textTargets(pid: pid_t) async -> [Target] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            // An app can own several layer-0 windows (Telegram keeps tiny helper ones): the biggest is the real UI.
            let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            log("screen: windows of pid \(pid): " + candidates.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) “\($0.title ?? "")”" }.joined(separator: ", "))
            // Map OCR boxes through the Accessibility window frame: that is the coordinate space clicks land in,
            // and SCWindow.frame was observed to disagree with it by a whole screen width.
            let axFrame = Actions.windowFrame(pid: pid)
            let area = { (w: SCWindow) in w.frame.width * w.frame.height }
            let window = axFrame.flatMap { ax in candidates.min { abs(area($0) - ax.width * ax.height) < abs(area($1) - ax.width * ax.height) } }
                ?? candidates.max { area($0) < area($1) }
            guard let window, window.frame.width > 100 else { return [] }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
            config.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ru-RU", "en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])

            let w = axFrame ?? window.frame
            log("screen: captured \(image.width)x\(image.height) px, OCR found \(request.results?.count ?? 0) lines")
            return (request.results ?? []).compactMap { line in
                guard let text = line.topCandidates(1).first?.string, text.count >= 2 else { return nil }
                let b = line.boundingBox  // normalised, origin bottom-left → screen points, origin top-left
                let frame = CGRect(x: w.minX + b.minX * w.width, y: w.minY + (1 - b.maxY) * w.height,
                                   width: b.width * w.width, height: b.height * w.height)
                return Target(label: String(text.prefix(60)), element: nil, frame: frame)
            }
        } catch {
            log("screen OCR failed: \(error.localizedDescription)")
            return []
        }
    }
}
