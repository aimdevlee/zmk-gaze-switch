import Foundation

/// The signals we read per frame, in a fixed order.
///
/// The eye is measured two ways: `eye*` is Vision's pupil landmark, `iris*`
/// is our own dark-pixel centroid inside the eye outline. They are noisy in
/// different ways, and the model weighs them by what calibration shows.
enum Feature: Int, CaseIterable {
    case headYaw, headPitch, eyeX, eyeY, irisX, irisY

    static let count = Feature.allCases.count
    static let head: [Feature] = [.headYaw, .headPitch]

    var label: String {
        switch self {
        case .headYaw: return "고개 좌우"
        case .headPitch: return "고개 상하"
        case .eyeX: return "눈 좌우"
        case .eyeY: return "눈 상하"
        case .irisX: return "홍채 좌우"
        case .irisY: return "홍채 상하"
        }
    }

    var isEye: Bool { self != .headYaw && self != .headPitch }

    /// Spread we assume on top of what calibration measured.
    ///
    /// A one-minute calibration is taken in one sitting posture, so signals
    /// look far steadier than they are over a working day. Without this the
    /// model leaned hard on head pitch (0.12 score per degree): slouching by
    /// 5° flipped every decision. Measured on real calibration data, these
    /// values keep all postures correct across a ±5° pitch change.
    var noiseFloor: Double {
        switch self {
        case .headYaw: return 1
        case .headPitch: return 5
        default: return 0.02  // eye signals; also tames the eyeX/irisX overlap
        }
    }

    func value(of pose: HeadPose) -> Double? {
        switch self {
        case .headYaw: return pose.yaw
        case .headPitch: return pose.pitch
        case .eyeX: return pose.eyeX
        case .eyeY: return pose.eyeY
        case .irisX: return pose.irisX
        case .irisY: return pose.irisY
        }
    }
}

/// Mean and covariance of the signals while the user looked at one target,
/// pooled over every posture in the calibration (head straight, head turned…).
struct TargetStats: Codable {
    var mean: [Double]  // Feature.count
    var cov: [Double]   // Feature.count², row-major
    var count: Int
    /// Eye signals are kept only if most frames had them. When false, the
    /// eye entries of `mean`/`cov` are zero and must not be used.
    var hasEyes: Bool

    init?(samples: [HeadPose]) {
        let withEyes = samples.filter(\.hasEyes)
        hasEyes = withEyes.count * 2 >= samples.count && withEyes.count >= 8
        let source = hasEyes ? withEyes : samples
        guard source.count >= 8 else { return nil }
        count = source.count

        let k = Feature.count
        let rows: [[Double]] = source.map { pose in Feature.allCases.map { $0.value(of: pose) ?? 0 } }
        let n = Double(rows.count)
        var m = [Double](repeating: 0, count: k)
        for row in rows { for i in 0..<k { m[i] += row[i] / n } }
        var c = [Double](repeating: 0, count: k * k)
        for row in rows {
            for i in 0..<k {
                for j in 0..<k { c[i * k + j] += (row[i] - m[i]) * (row[j] - m[j]) / (n - 1) }
            }
        }
        mean = m
        cov = c
    }
}

/// A two-class linear discriminant learned from the two calibrations.
///
/// It uses the full covariance between signals, not each signal on its own.
/// That matters once calibration mixes postures: looking at one screen with
/// the head straight puts the pupils off-centre, and with the head turned
/// puts them back in the middle. Taken separately, head and eye signals are
/// both ambiguous; their combination ("head angle + eye angle") is not, and
/// w = S⁻¹·Δ finds exactly that combination from the data.
///
/// `score` is normalised so the Mac calibration sits at -0.5 and the other
/// computer's at +0.5; 0 is halfway.
struct GazeModel {
    let mac: TargetStats
    let other: TargetStats

    private struct Weights {
        var features: [Feature]
        var w: [Double]
        var mid: [Double]
        var denominator: Double  // w·Δ = squared Mahalanobis distance
    }

    private let headOnly: Weights?
    private let withEyes: Weights?

    var hasEyes: Bool { withEyes != nil }

    init(mac: TargetStats, other: TargetStats) {
        self.mac = mac
        self.other = other
        headOnly = Self.solve(mac, other, Feature.head)
        withEyes = mac.hasEyes && other.hasEyes ? Self.solve(mac, other, Feature.allCases) : nil
    }

    private static func solve(_ mac: TargetStats, _ other: TargetStats, _ features: [Feature]) -> Weights? {
        let k = features.count
        var s = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var delta = [Double](repeating: 0, count: k)
        var mid = [Double](repeating: 0, count: k)
        for (a, fa) in features.enumerated() {
            let i = fa.rawValue
            delta[a] = other.mean[i] - mac.mean[i]
            mid[a] = (other.mean[i] + mac.mean[i]) / 2
            for (b, fb) in features.enumerated() {
                let j = fb.rawValue
                s[a][b] = (mac.cov[i * Feature.count + j] + other.cov[i * Feature.count + j]) / 2
            }
            s[a][a] += fa.noiseFloor * fa.noiseFloor  // ridge: keeps S invertible
        }
        guard let w = gaussSolve(s, delta) else { return nil }
        let denominator = zip(w, delta).map(*).reduce(0, +)
        guard denominator.isFinite, denominator > 1e-9 else { return nil }
        return Weights(features: features, w: w, mid: mid, denominator: denominator)
    }

    /// Solves A·x = b by Gaussian elimination with partial pivoting.
    private static func gaussSolve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a
        var v = b
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }),
                  abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            v.swapAt(col, pivot)
            for row in (col + 1)..<n where n > col + 1 {
                let f = m[row][col] / m[col][col]
                for c in col..<n { m[row][c] -= f * m[col][c] }
                v[row] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for c in (row + 1)..<n where n > row + 1 { sum -= m[row][c] * x[c] }
            x[row] = sum / m[row][row]
        }
        return x
    }

    /// How many spreads apart the two targets are on one signal alone.
    /// With mixed-posture calibration each single signal can look weak even
    /// when the combination (`totalSeparation`) is strong.
    func separation(_ f: Feature) -> Double? {
        guard !f.isEye || hasEyes else { return nil }
        let i = f.rawValue
        let d = i * Feature.count + i
        let variance = (mac.cov[d] + other.cov[d]) / 2 + f.noiseFloor * f.noiseFloor
        return abs(other.mean[i] - mac.mean[i]) / variance.squareRoot()
    }

    /// Separation of the combined signals. Below ~2 the two targets overlap
    /// enough that switching will be unreliable.
    func totalSeparation(useEyes: Bool) -> Double {
        let weights = (useEyes ? withEyes : nil) ?? headOnly
        return weights.map { $0.denominator.squareRoot() } ?? 0
    }

    /// -0.5 ≈ looking at the Mac, +0.5 ≈ looking at the other computer.
    func score(_ pose: HeadPose, useEyes: Bool) -> Double? {
        guard let weights = (useEyes && pose.hasEyes ? withEyes : nil) ?? headOnly else { return nil }
        var sum = 0.0
        for (a, f) in weights.features.enumerated() {
            guard let x = f.value(of: pose) else { return nil }
            sum += weights.w[a] * (x - weights.mid[a])
        }
        return sum / weights.denominator
    }
}
