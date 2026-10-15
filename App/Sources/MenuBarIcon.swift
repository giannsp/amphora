import AppKit

/// The menu bar icon: the amphora from the app icon, drawn as a template image so macOS tints it for
/// light and dark menu bars. The jar fills with how much of your fleet is ready to restore, and rises
/// with download progress during a sync. A badge marks something that needs you.
enum MenuBarIcon {
    enum Badge: Hashable { case none, attention }

    /// `fill` is 0…1: the share of models whose restore file is ready (plus download progress).
    @MainActor
    static func image(fill: Double, badge: Badge = .none, height: CGFloat = 16) -> NSImage {
        // Quantize so a running download redraws at most a couple of dozen times, not per byte.
        let steps = 24.0
        var level = (min(max(fill, 0), 1) * steps).rounded(.down) / steps
        if fill > 0 && level < 0.15 { level = 0.15 }   // some progress should always be visible
        if fill >= 1 { level = 1 }
        let key = CacheKey(level: level, badge: badge, height: height)
        if let cached = cache[key] { return cached }

        let size = NSSize(width: (height * viewBox.width / viewBox.height).rounded(.up), height: height)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: cg, rect: rect, level: level, badge: badge)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Amphora"
        cache[key] = image
        return image
    }

    // MARK: Drawing (coordinates are the app icon SVG's: 1024-unit canvas, y down)

    private static let viewBox = CGRect(x: 262, y: 196, width: 530, height: 660)
    private static let lineWidth: CGFloat = 40
    private static let vesselTop: CGFloat = 222, vesselBottom: CGFloat = 830
    private static let band = CGRect(x: 200, y: 566, width: 700, height: 40)
    private static let badgeCenter = CGPoint(x: 640, y: 742), badgeRadius: CGFloat = 128

    private static func draw(in cg: CGContext, rect: CGRect, level: Double, badge: Badge) {
        let scale = rect.height / viewBox.height
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -viewBox.minX, y: -viewBox.minY)
        cg.setFillColor(.black)
        cg.setStrokeColor(.black)

        // Contents: everything below the fill line, with the glaze band left clear.
        if level > 0 {
            cg.saveGState()
            cg.addPath(vessel)
            cg.clip()
            let y = vesselBottom - CGFloat(level) * (vesselBottom - vesselTop)
            cg.fill(CGRect(x: 200, y: y, width: 700, height: 900))
            cg.setBlendMode(.clear)
            cg.fill(band)
            cg.restoreGState()
        }

        // The jar itself, always.
        cg.setLineWidth(lineWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.addPath(vessel)
        cg.addPath(handles)
        cg.strokePath()

        if badge == .attention {
            let c = badgeCenter
            cg.setBlendMode(.clear)   // a gap around the badge so it reads as separate
            cg.fillEllipse(in: CGRect(x: c.x - badgeRadius - 44, y: c.y - badgeRadius - 44,
                                      width: (badgeRadius + 44) * 2, height: (badgeRadius + 44) * 2))
            cg.setBlendMode(.normal)
            cg.fillEllipse(in: CGRect(x: c.x - badgeRadius, y: c.y - badgeRadius,
                                      width: badgeRadius * 2, height: badgeRadius * 2))
            cg.setBlendMode(.clear)   // "!" cut out of the badge
            cg.addPath(CGPath(roundedRect: CGRect(x: c.x - 19, y: c.y - 84, width: 38, height: 104),
                              cornerWidth: 19, cornerHeight: 19, transform: nil))
            cg.fillPath()
            cg.fillEllipse(in: CGRect(x: c.x - 22, y: c.y + 36, width: 44, height: 44))
        }
    }

    /// The vessel outline, the same path as `docs/images/icon.svg`.
    private static let vessel = path("""
        M420 222 H604 Q620 222 620 236 Q620 250 604 252 C584 256 576 266 575 288 C574 318 586 340 616 358 \
        C690 400 732 456 732 532 C732 628 666 704 600 748 C584 760 576 772 576 786 V796 C612 802 632 814 632 830 \
        H392 C392 814 412 802 448 796 V786 C448 772 440 760 424 748 C358 704 292 628 292 532 \
        C292 456 334 400 408 358 C438 340 450 318 449 288 C448 266 440 256 420 252 Q404 250 404 236 Q404 222 420 222 Z
        """)
    private static let handles = path("M452 284 C352 266 290 304 318 410 M572 284 C672 266 734 304 706 410")

    /// Just enough SVG path syntax for the shapes above: absolute M, H, V, Q, C and Z.
    private static func path(_ d: String) -> CGPath {
        let p = CGMutablePath()
        // Letters and numbers may touch ("M420"), so tokenize by pattern rather than by spaces.
        var tokens = d.matches(of: #/[A-Za-z]|-?[0-9.]+/#).map { String($0.output) }[...]
        var command = ""
        func number() -> CGFloat { CGFloat(Double(tokens.popFirst() ?? "0") ?? 0) }
        func point() -> CGPoint { let x = number(); return CGPoint(x: x, y: number()) }
        while let token = tokens.first {
            if token.first?.isLetter == true { command = token; tokens.removeFirst() }
            switch command {
            case "M": p.move(to: point())
            case "H": p.addLine(to: CGPoint(x: number(), y: p.currentPoint.y))
            case "V": p.addLine(to: CGPoint(x: p.currentPoint.x, y: number()))
            case "Q": let c = point(); p.addQuadCurve(to: point(), control: c)
            case "C": let c1 = point(), c2 = point(); p.addCurve(to: point(), control1: c1, control2: c2)
            case "Z": p.closeSubpath()
            default: tokens.removeFirst()
            }
        }
        return p
    }

    private struct CacheKey: Hashable { let level: Double; let badge: Badge; let height: CGFloat }
    @MainActor private static var cache: [CacheKey: NSImage] = [:]
}
