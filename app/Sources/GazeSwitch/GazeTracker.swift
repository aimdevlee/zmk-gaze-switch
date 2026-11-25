import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// One reading of where the user is looking.
///
/// - yaw / pitch: head rotation in degrees (left/right, up/down).
/// - eyeX / eyeY: where the pupils sit inside the eyes, as a fraction of eye
///   width from the eye's centre (about -0.5…0.5; real use is within ±0.2).
///   nil when the eyes are closed or the landmarks weren't usable.
struct HeadPose {
    var yaw: Double
    var pitch: Double
    var eyeX: Double? = nil
    var eyeY: Double? = nil
    /// Same idea as eyeX/eyeY, but from our own dark-pixel centroid.
    var irisX: Double? = nil
    var irisY: Double? = nil

    var hasEyes: Bool { eyeX != nil && eyeY != nil && irisX != nil && irisY != nil }
}

/// Runs the built-in camera at a low rate and reports the head pose (and pupil
/// position) of the largest face, or nil when no face is visible.
final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onPose: ((HeadPose?) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "gaze-switch.camera")
    private var lastFrame = Date.distantPast
    private let frameInterval: TimeInterval = 0.1
    private var configured = false

    /// Pupil readings jump a little from frame to frame; smooth them.
    private var smoothEye: [Double]?  // eyeX, eyeY, irisX, irisY

    /// Diagnostics: while a label is set, about two frames a second are saved
    /// as enlarged crops of the eye area with the measurements drawn on top.
    /// They stay on this Mac, in Application Support/GazeSwitch/eyes.
    private var debugLabel: String?
    private var debugCount = 0
    private var frameNumber = 0
    private let ciContext = CIContext()

    static var debugDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GazeSwitch/eyes")
    }

    func setDebugLabel(_ label: String?) {
        queue.async {
            self.debugLabel = label
            self.debugCount = 0
        }
    }
    private let eyeSmoothing = 0.4

    // Built once and reused on the capture queue. Setting `revision` makes
    // Vision re-check its list of supported revisions, which cost about a
    // fifth of the per-frame time when these were created for every frame.
    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        // Revision 3 reports continuous yaw and pitch; earlier ones quantize yaw to 45°.
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()
    private let landmarkRequest: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        return request
    }()

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    func start() throws {
        queue.sync {
            if !configured { try? configure() }
        }
        guard configured else { throw NSError(domain: "GazeSwitch", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: tr("카메라를 찾지 못했어요", "No camera found", "カメラが見つかりません")]) }
        queue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.smoothEye = nil
        }
    }

    private func configure() throws {
        // Prefer the built-in camera: its position relative to the MacBook screen is fixed.
        let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                      mediaType: .video, position: .unspecified).devices.first
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { return }

        session.beginConfiguration()
        // Pupils are only a few pixels wide at VGA; 720p gives Vision enough to work with.
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .vga640x480
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        output.alwaysDiscardsLateVideoFrames = true
        // BGRA so the iris search can read pixels directly.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastFrame) >= frameInterval,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now

        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)

        let faces = faceRequest
        try? handler.perform([faces])

        let face = (faces.results ?? []).max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        guard let face, let yaw = face.yaw?.doubleValue else {
            smoothEye = nil
            DispatchQueue.main.async { self.onPose?(nil) }
            return
        }
        var pose = HeadPose(yaw: yaw * 180 / .pi, pitch: (face.pitch?.doubleValue ?? 0) * 180 / .pi)

        // Landmarks only for the face we already picked: cheaper than searching again.
        let landmarks = landmarkRequest
        landmarks.inputFaceObservations = [face]
        try? handler.perform([landmarks])

        frameNumber += 1
        // With a mask (or a hand) over the nose and mouth, Vision still returns
        // landmarks, but they land in the wrong place, tiny and rotated. Using
        // them would feed noise to the model, so check they look like a face.
        let marks = landmarks.results?.first?.landmarks.flatMap { Self.plausible($0, roll: face.roll?.doubleValue) ? $0 : nil }
        eyesTrusted = marks != nil

        if let label = debugLabel, frameNumber % 4 == 0, let raw = landmarks.results?.first?.landmarks {
            saveEyeDebug(pixels, raw, label + (marks == nil ? "-rejected" : ""))
        }

        if let marks,
           let eyes = Self.pupilOffset(marks),
           let iris = Self.irisOffset(marks, pixels) {
            let now = [Double(eyes.x), Double(eyes.y), Double(iris.x), Double(iris.y)]
            if let old = smoothEye {
                smoothEye = zip(old, now).map { $0 + ($1 - $0) * eyeSmoothing }
            } else {
                smoothEye = now
            }
        }
        if marks == nil { smoothEye = nil }
        // Eyes closed for a frame (a blink): carry the last smoothed reading so
        // the classifier doesn't flip between eye-on and eye-off scoring.
        if let e = smoothEye {
            pose.eyeX = e[0]
            pose.eyeY = e[1]
            pose.irisX = e[2]
            pose.irisY = e[3]
        }

        DispatchQueue.main.async { self.onPose?(pose) }
    }

    /// Whether the last frame's eye landmarks passed the sanity check.
    private(set) var eyesTrusted = true

    /// Landmarks of a real, roughly upright face: the eyes sit side by side
    /// and about a third of the face box apart. (Coordinates are relative to
    /// the face box, so this doesn't depend on distance from the camera.)
    static func plausible(_ marks: VNFaceLandmarks2D, roll: Double?) -> Bool {
        if let roll, abs(roll) > 0.6 { return false }  // ~35°
        guard let l = marks.leftEye, let r = marks.rightEye, l.pointCount >= 4, r.pointCount >= 4 else { return false }
        func centre(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let p = region.normalizedPoints, n = CGFloat(p.count)
            return CGPoint(x: p.map(\.x).reduce(0, +) / n, y: p.map(\.y).reduce(0, +) / n)
        }
        let a = centre(l), b = centre(r)
        let dx = abs(a.x - b.x), dy = abs(a.y - b.y)
        return dx > 0.2 && dy < dx * 0.7
    }

    /// Average pupil offset of both eyes, measured along each eye's own
    /// corner-to-corner axis so a tilted head doesn't read as a sideways look.
    private static func pupilOffset(_ marks: VNFaceLandmarks2D) -> CGPoint? {
        let pairs: [(VNFaceLandmarkRegion2D?, VNFaceLandmarkRegion2D?)] = [
            (marks.leftEye, marks.leftPupil), (marks.rightEye, marks.rightPupil),
        ]
        let offsets = pairs.compactMap { eye, pupil -> CGPoint? in
            guard let eye, let pupil, eye.pointCount >= 4, pupil.pointCount >= 1 else { return nil }
            return offset(contour: Array(eye.normalizedPoints), pupil: pupil.normalizedPoints[0])
        }
        guard !offsets.isEmpty else { return nil }
        let n = CGFloat(offsets.count)
        return CGPoint(x: offsets.map(\.x).reduce(0, +) / n, y: offsets.map(\.y).reduce(0, +) / n)
    }

    /// Writes a 5× crop of both eyes with the eye outline (green), our dark
    /// centroid (red) and Vision's pupil point (blue) drawn on it.
    private func saveEyeDebug(_ pixels: CVPixelBuffer, _ marks: VNFaceLandmarks2D, _ label: String) {
        guard let dir = Self.debugDirectory,
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let size = CGSize(width: width, height: height)
        func down(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: CGFloat(height) - $0.y) }
        }
        let contours = [down(marks.leftEye), down(marks.rightEye)].filter { $0.count >= 4 }
        let pupils = down(marks.leftPupil) + down(marks.rightPupil)
        guard !contours.isEmpty else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let centroids: [CGPoint] = contours.compactMap { contour in
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
            return Self.darkCentroid(contour, base.assumingMemoryBound(to: UInt8.self), width, height,
                                     CVPixelBufferGetBytesPerRow(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)

        let all = contours.flatMap { $0 }
        let margin: CGFloat = 18
        let x0 = max(0, all.map(\.x).min()! - margin), x1 = min(CGFloat(width), all.map(\.x).max()! + margin)
        let y0 = max(0, all.map(\.y).min()! - margin), y1 = min(CGFloat(height), all.map(\.y).max()! + margin)
        let crop = CGRect(x: x0.rounded(), y: y0.rounded(), width: (x1 - x0).rounded(), height: (y1 - y0).rounded())
        guard crop.width > 8, crop.height > 8 else { return }

        // Core Image has y up; our crop rect has y down.
        let ciRect = CGRect(x: crop.minX, y: CGFloat(height) - crop.maxY, width: crop.width, height: crop.height)
        guard let image = ciContext.createCGImage(CIImage(cvPixelBuffer: pixels), from: ciRect) else { return }

        let scale: CGFloat = 5
        let w = Int(crop.width * scale), h = Int(crop.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - crop.minX) * scale, y: (crop.maxY - p.y) * scale) }

        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(red: 0, green: 1, blue: 0, alpha: 0.9))
        for contour in contours {
            ctx.addLines(between: contour.map(map))
            ctx.closePath()
            ctx.strokePath()
        }
        func mark(_ p: CGPoint, _ color: CGColor) {
            let c = map(p)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
            ctx.move(to: CGPoint(x: c.x - 9, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 9, y: c.y))
            ctx.move(to: CGPoint(x: c.x, y: c.y - 9)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 9))
            ctx.strokePath()
        }
        centroids.forEach { mark($0, CGColor(red: 1, green: 0, blue: 0, alpha: 1)) }
        pupils.forEach { mark($0, CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)) }

        guard let out = ctx.makeImage() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        debugCount += 1
        let url = dir.appendingPathComponent(String(format: "%@-%02d.png", label, debugCount))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Iris position found directly in the pixels: the centroid of the darkest
    /// part of each eye opening, then expressed like `pupilOffset`.
    private static func irisOffset(_ marks: VNFaceLandmarks2D, _ pixels: CVPixelBuffer) -> CGPoint? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let size = CGSize(width: width, height: height)

        let offsets = [marks.leftEye, marks.rightEye].compactMap { eye -> CGPoint? in
            guard let eye, eye.pointCount >= 4 else { return nil }
            // Vision's image points have y up; pixel rows go down.
            let contour = eye.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: CGFloat(height) - $0.y) }
            guard let centre = darkCentroid(contour, bytes, width, height, rowBytes) else { return nil }
            return offset(contour: contour, pupil: centre)
        }
        guard offsets.count == 2 else { return nil }  // one eye alone is biased toward its corner
        return CGPoint(x: (offsets[0].x + offsets[1].x) / 2, y: (offsets[0].y + offsets[1].y) / 2)
    }

    /// Darkness-weighted centroid of the darkest 30% of pixels inside a polygon.
    private static func darkCentroid(_ polygon: [CGPoint], _ bytes: UnsafePointer<UInt8>,
                                     _ width: Int, _ height: Int, _ rowBytes: Int) -> CGPoint? {
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        let x0 = max(0, Int(xs.min()!)), x1 = min(width - 1, Int(xs.max()!.rounded(.up)))
        let y0 = max(0, Int(ys.min()!)), y1 = min(height - 1, Int(ys.max()!.rounded(.up)))
        guard x1 > x0, y1 > y0, (x1 - x0) * (y1 - y0) < 40_000 else { return nil }

        var inside: [(x: Int, y: Int, lum: Double)] = []
        for y in y0...y1 {
            for x in x0...x1 where contains(polygon, CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                let p = bytes + y * rowBytes + x * 4
                inside.append((x, y, 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])))
            }
        }
        guard inside.count >= 30 else { return nil }
        let threshold = inside.map(\.lum).sorted()[inside.count * 3 / 10]
        var sx = 0.0, sy = 0.0, sw = 0.0
        for p in inside where p.lum <= threshold {
            let w = threshold - p.lum + 1
            sx += w * (Double(p.x) + 0.5)
            sy += w * (Double(p.y) + 0.5)
            sw += w
        }
        return sw > 0 ? CGPoint(x: sx / sw, y: sy / sw) : nil
    }

    private static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Pupil position relative to one eye: x along the corner axis (-0.5…0.5),
    /// y across it, both in eye widths. nil if the eye looks closed.
    static func offset(contour: [CGPoint], pupil: CGPoint) -> CGPoint? {
        guard let inner = contour.min(by: { $0.x < $1.x }),
              let outer = contour.max(by: { $0.x < $1.x }) else { return nil }
        let ax = outer.x - inner.x, ay = outer.y - inner.y
        let width = hypot(ax, ay)
        guard width > 0 else { return nil }
        let ux = ax / width, uy = ay / width  // along the eye
        let nx = -uy, ny = ux                 // across the eye

        // Openness: how tall the contour is across the axis, relative to its width.
        let across = contour.map { ($0.x - inner.x) * nx + ($0.y - inner.y) * ny }
        guard let lo = across.min(), let hi = across.max(), (hi - lo) / width >= 0.12 else { return nil }

        let px = pupil.x - inner.x, py = pupil.y - inner.y
        let along = (px * ux + py * uy) / width - 0.5
        let mid = (lo + hi) / 2
        let up = ((px * nx + py * ny) - mid) / width
        return CGPoint(x: along, y: up)
    }
}

enum Target: String {
    case mac, other
}

/// Turns a stream of poses into a stable target.
///
/// - The calibrated `model` gives each frame a score: -0.5 ≈ Mac, +0.5 ≈ other.
/// - The score is averaged over a short time to tame frame-to-frame jitter.
/// - Hysteresis: the score has to cross ±`band` to change sides; in between,
///   the current target stays.
/// - A new target must win for `dwell` seconds before it is reported.
/// - No face (or no usable signal) holds the current target.
struct GazeClassifier {
    var model: GazeModel?
    var useEyes = true
    var dwell: TimeInterval = 0.4
    /// Eyes-only glances score about ±0.2 on real data, so the band must sit below that.
    var band: Double = 0.08
    /// Time constant for averaging the score. Per-frame eye readings jitter;
    /// averaging ~4 frames cuts that noise roughly in half.
    var smoothing: TimeInterval = 0.35

    private(set) var current: Target = .mac
    private(set) var lastScore: Double?
    private var candidate: Target?
    private var candidateSince = Date()
    private var lastFeed: Date?

    /// Returns the new target when it changes.
    mutating func feed(_ pose: HeadPose?, now: Date = Date()) -> Target? {
        guard let pose, let model, let raw = model.score(pose, useEyes: useEyes) else {
            lastScore = nil
            lastFeed = nil
            candidate = nil
            return nil
        }
        var score = raw
        if let previous = lastScore, let lastFeed {
            let dt = max(0, now.timeIntervalSince(lastFeed))
            score = previous + (raw - previous) * (1 - exp(-dt / smoothing))
        }
        lastScore = score
        lastFeed = now

        let wanted: Target
        if score > band { wanted = .other }
        else if score < -band { wanted = .mac }
        else { wanted = current }

        guard wanted != current else {
            candidate = nil
            return nil
        }
        if candidate != wanted {
            candidate = wanted
            candidateSince = now
            return nil
        }
        guard now.timeIntervalSince(candidateSince) >= dwell else { return nil }
        current = wanted
        candidate = nil
        return wanted
    }

    mutating func force(_ target: Target) {
        current = target
        candidate = nil
        lastScore = nil
        lastFeed = nil
    }
}
