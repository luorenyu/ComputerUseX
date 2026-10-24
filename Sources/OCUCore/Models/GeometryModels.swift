import Foundation
import CoreGraphics

public struct ScreenPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = (x * 10).rounded() / 10
        self.y = (y * 10).rounded() / 10
    }

    public init(_ cgPoint: CGPoint) {
        self.init(x: Double(cgPoint.x), y: Double(cgPoint.y))
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    public func distance(to other: ScreenPoint) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }
}

public struct ScreenRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = (x * 10).rounded() / 10
        self.y = (y * 10).rounded() / 10
        self.width = (width * 10).rounded() / 10
        self.height = (height * 10).rounded() / 10
    }

    public init(_ cgRect: CGRect) {
        self.init(
            x: Double(cgRect.origin.x),
            y: Double(cgRect.origin.y),
            width: Double(cgRect.size.width),
            height: Double(cgRect.size.height)
        )
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public var center: ScreenPoint {
        ScreenPoint(x: x + width / 2.0, y: y + height / 2.0)
    }

    public var area: Double {
        max(0, width) * max(0, height)
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ point: ScreenPoint) -> Bool {
        point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY
    }

    public func intersectionArea(with other: ScreenRect) -> Double {
        let ix1 = max(x, other.x)
        let iy1 = max(y, other.y)
        let ix2 = min(maxX, other.maxX)
        let iy2 = min(maxY, other.maxY)
        if ix2 <= ix1 || iy2 <= iy1 {
            return 0
        }
        return (ix2 - ix1) * (iy2 - iy1)
    }

    public func intersectionOverUnion(with other: ScreenRect) -> Double {
        let inter = intersectionArea(with: other)
        if inter <= 0 { return 0 }
        let union = area + other.area - inter
        guard union > 0 else { return 0 }
        return inter / union
    }

    /// Checks whether an OCR text box is already covered by an existing AX element
    public func overlapsSignificantly(with other: ScreenRect) -> Bool {
        if intersectionOverUnion(with: other) >= 0.45 {
            return true
        }
        let inter = intersectionArea(with: other)
        let minArea = min(area, other.area)
        if minArea > 0 && (inter / minArea) >= 0.75 {
            return true
        }
        return other.contains(center) && other.area <= area * 4.5
    }
}

public enum CubicBezierTrajectory {
    /// Generates human-like smooth trajectory points between `start` and `end`
    /// using a cubic Bézier curve with smoothstep (ease-in-out) velocity profile.
    public static func sample(
        from start: ScreenPoint,
        to end: ScreenPoint,
        steps: Int = 18,
        curvature: Double = 0.14
    ) -> [ScreenPoint] {
        let totalSteps = max(2, steps)
        let dist = start.distance(to: end)
        if dist < 2.0 {
            return [end]
        }

        let dx = end.x - start.x
        let dy = end.y - start.y
        // Perpendicular unit vector for subtle natural arc
        let nx = -dy / dist
        let ny = dx / dist
        let arcOffset = min(65.0, dist * curvature)

        let control1 = ScreenPoint(
            x: start.x + dx * 0.28 + nx * arcOffset,
            y: start.y + dy * 0.28 + ny * arcOffset
        )
        let control2 = ScreenPoint(
            x: start.x + dx * 0.72 + nx * (arcOffset * 0.45),
            y: start.y + dy * 0.72 + ny * (arcOffset * 0.45)
        )

        var points: [ScreenPoint] = []
        points.reserveCapacity(totalSteps)

        for i in 1...totalSteps {
            let linearT = Double(i) / Double(totalSteps)
            // Smoothstep ease-in-out: 3t^2 - 2t^3
            let t = linearT * linearT * (3.0 - 2.0 * linearT)
            let u = 1.0 - t

            let bx = u * u * u * start.x
                + 3.0 * u * u * t * control1.x
                + 3.0 * u * t * t * control2.x
                + t * t * t * end.x

            let by = u * u * u * start.y
                + 3.0 * u * u * t * control1.y
                + 3.0 * u * t * t * control2.y
                + t * t * t * end.y

            points.append(ScreenPoint(x: bx, y: by))
        }

        points[points.count - 1] = end
        return points
    }
}
