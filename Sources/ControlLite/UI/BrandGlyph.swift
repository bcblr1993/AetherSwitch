import AppKit

/// S 形开关：同一套几何用于应用图标、菜单栏和面板标题。
enum BrandGlyph {
    static func draw(in rect: NSRect, color: NSColor, secondary: NSColor? = nil, knobColor: NSColor? = nil) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let path = NSBezierPath()
        path.move(to: point(0.80, 0.22))
        path.line(to: point(0.34, 0.22))
        path.curve(to: point(0.34, 0.50), controlPoint1: point(0.06, 0.22), controlPoint2: point(0.06, 0.50))
        path.line(to: point(0.66, 0.50))
        path.curve(to: point(0.66, 0.78), controlPoint1: point(0.94, 0.50), controlPoint2: point(0.94, 0.78))
        path.line(to: point(0.20, 0.78))
        path.lineWidth = min(rect.width, rect.height) * 0.21
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        if let secondary, let context = NSGraphicsContext.current?.cgContext {
            NSGraphicsContext.saveGraphicsState()
            context.addPath(path.cgPath)
            context.setLineWidth(path.lineWidth)
            context.setLineCap(.round); context.setLineJoin(.round)
            context.replacePathWithStrokedPath(); context.clip()
            NSGradient(starting: color, ending: secondary)?.draw(in: rect, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
        } else { color.setStroke(); path.stroke() }
        let diameter = min(rect.width, rect.height) * 0.155
        let center = point(0.80, 0.22)
        let knob = NSBezierPath(ovalIn: NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
        if let knobColor { knobColor.setFill(); knob.fill() }
        else {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            knob.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    static func templateImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            draw(in: rect.insetBy(dx: 0.5, dy: 0), color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AetherSwitch"
        return image
    }
}
