import UIKit

/// Covers of the demo tracks, drawn on the phone: a two-tone gradient with record grooves.
/// Real tracks get their covers from the files (`djtag import`).
enum DemoArtwork {
    static let prefix = "demo/"

    static func key(_ index: Int) -> String { "\(prefix)\(index)" }

    private static let palettes: [(UInt32, UInt32)] = [
        (0x1D2671, 0xC33764), (0x0F2027, 0x2C5364), (0xFF512F, 0xDD2476), (0x134E5E, 0x71B280),
        (0x41295A, 0x2F0743), (0xF7971E, 0xFFD200), (0x3A1C71, 0xD76D77), (0x000428, 0x004E92),
        (0xED213A, 0x93291E), (0x4B79A1, 0x283E51), (0x8E2DE2, 0x4A00E0), (0x16222A, 0x3A6073),
    ]

    /// The cover for a demo key (`demo/<index>`), or nil for any other key.
    nonisolated static func image(key: String, pixels: Int) -> UIImage? {
        guard key.hasPrefix(prefix), let index = Int(key.dropFirst(prefix.count)) else { return nil }
        let (from, to) = palettes[index % palettes.count]
        let side = CGFloat(pixels)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            let colors = [color(from).cgColor, color(to).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                let flip = index % 2 == 0
                cg.drawLinearGradient(
                    gradient, start: CGPoint(x: flip ? 0 : side, y: 0), end: CGPoint(x: flip ? side : 0, y: side),
                    options: [])
            }
            // A record, partly out of the frame.
            let center = CGPoint(x: side * (0.62 + 0.04 * CGFloat(index % 3)), y: side * 0.66)
            cg.setStrokeColor(UIColor(white: 1, alpha: 0.10).cgColor)
            cg.setLineWidth(max(1, side / 150))
            for ring in 0..<7 {
                let radius = side * (0.16 + 0.07 * CGFloat(ring))
                cg.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            let label = side * 0.09
            cg.setFillColor(UIColor(white: 1, alpha: 0.28).cgColor)
            cg.fillEllipse(in: CGRect(x: center.x - label, y: center.y - label, width: label * 2, height: label * 2))
        }
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
