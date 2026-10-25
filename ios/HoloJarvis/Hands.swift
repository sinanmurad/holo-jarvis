import Foundation
import CoreGraphics
import CoreVideo
import Vision

/// One detected hand, already converted to screen (view) points.
struct HandSample {
    var thumb: CGPoint
    var index: CGPoint
    var wrist: CGPoint
    var middle: CGPoint
}

/// Hand pose detection on the AR camera image (Apple Vision, runs on-device).
enum HandDetector {
    private static let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    /// `transform` is ARFrame.displayTransform(for:viewportSize:), mapping normalized image
    /// coordinates (top-left origin) to normalized view coordinates.
    static func detect(_ buffer: CVPixelBuffer, transform: CGAffineTransform, size: CGSize) -> [HandSample] {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let observations = request.results else { return [] }

        func toView(_ p: VNRecognizedPoint) -> CGPoint {
            let n = CGPoint(x: p.location.x, y: 1 - p.location.y).applying(transform)
            return CGPoint(x: n.x * size.width, y: n.y * size.height)
        }

        var out: [HandSample] = []
        for o in observations {
            guard let pts = try? o.recognizedPoints(.all),
                  let t = pts[.thumbTip], let i = pts[.indexTip],
                  let w = pts[.wrist], let m = pts[.middleMCP],
                  t.confidence > 0.3, i.confidence > 0.3, w.confidence > 0.2, m.confidence > 0.2 else { continue }
            out.append(HandSample(thumb: toView(t), index: toView(i), wrist: toView(w), middle: toView(m)))
        }
        return out
    }
}

/// Tracks one hand across frames and remembers what it is doing.
final class HandState {
    var x: CGFloat
    var y: CGFloat
    var sample: HandSample?
    var seen: TimeInterval
    var pinch = false
    var startPoint = CGPoint.zero
    var startTime: TimeInterval = 0
    var startPanel: Panel?
    var startPixel: CGPoint?
    var dragging = false
    var grabDistance: Float = 1.5
    var grabOffset = SIMD3<Float>(0, 0, 0)

    init(x: CGFloat, y: CGFloat, seen: TimeInterval) {
        self.x = x
        self.y = y
        self.seen = seen
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
}
