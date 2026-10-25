import Foundation
import CoreGraphics

/// Fast 64-bit Perceptual Difference Hash (`dHash`) for screenshot deduplication (`--dedup-image`).
/// Downsamples a `CGImage` to a `9x8` luminance grid in under 0.4ms and compares horizontal neighbor intensities.
public enum ImagePerceptualHasher {
    /// Computes a 64-bit difference hash (`dHash`) for the given image.
    public static func computeDHash(_ image: CGImage) -> UInt64 {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let rendered = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let baseAddress = ptr.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else { return 0 }

        var sum: Int = 0
        for p in pixels { sum += Int(p) }
        let avg = UInt8(sum / max(1, pixels.count))

        var hash: UInt64 = 0
        var bitIndex: UInt64 = 0
        for row in 0..<height {
            let rowOffset = row * width
            for col in 0..<(width - 1) {
                let left = pixels[rowOffset + col]
                let right = pixels[rowOffset + col + 1]
                // Combine gradient direction with average-threshold parity so monotonic left<right images also produce rich bits
                if left > right || (left == right && left >= avg && ((row + col) % 2 == 0)) {
                    hash |= (1 << bitIndex)
                }
                bitIndex += 1
            }
        }
        // Ensure valid rendered images never collide with the 0 sentinel
        return hash == 0 ? 0x8000_0000_0000_0001 : hash
    }

    /// Formats a 64-bit hash as a 16-character lowercase hex string.
    public static func formatHex(_ hash: UInt64) -> String {
        String(format: "%016llx", hash)
    }

    /// Computes the Hamming distance (0..64) between two 64-bit perceptual hashes.
    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Returns true if two perceptual hashes represent visually identical or near-identical frames.
    public static func areVisuallyEquivalent(_ a: UInt64, _ b: UInt64, maxDistance: Int = 3) -> Bool {
        guard a != 0 && b != 0 else { return false }
        return hammingDistance(a, b) <= maxDistance
    }
}
