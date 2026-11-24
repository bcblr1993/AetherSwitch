import AppKit

/// 双开关液态遥测矢量标识：呼应应用图标的「控制 + 监控」双胶囊几何，
/// 统一用于状态栏图标、折叠占位符与面板头部（自动适配 flipped 与非 flipped 坐标系）。
enum BrandGlyph {
    static func draw(in rect: NSRect, color: NSColor, secondary: NSColor? = nil, knobColor: NSColor? = nil) {
        guard rect.width > 1, rect.height > 1 else { return }
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        let w = rect.width
        let h = rect.height
        let insetX = max(0.5, w * 0.04)
        let pillW = max(1, w - insetX * 2)
        let pillH = h * 0.42
        let gap = h * 0.12
        let topYFromTop = (h - (pillH * 2 + gap)) / 2
        let bottomYFromTop = topYFromTop + pillH + gap

        func pillRect(yFromTop: CGFloat) -> NSRect {
            let originY = isFlipped
                ? rect.minY + yFromTop
                : rect.maxY - yFromTop - pillH
            return NSRect(x: rect.minX + insetX, y: originY, width: pillW, height: pillH)
        }

        func pointIn(_ box: NSRect, nx: CGFloat, nyFromTop: CGFloat) -> NSPoint {
            let x = box.minX + nx * box.width
            let y = isFlipped
                ? box.minY + nyFromTop * box.height
                : box.maxY - nyFromTop * box.height
            return NSPoint(x: x, y: y)
        }

        let topRect = pillRect(yFromTop: topYFromTop)
        let bottomRect = pillRect(yFromTop: bottomYFromTop)
        let strokeW = max(1.15, min(w, h) * 0.085)

        let topKnobDiameter = pillH * 0.68
        let topKnobCenter = NSPoint(x: topRect.maxX - pillH / 2, y: topRect.midY)
        let topKnob = NSBezierPath(ovalIn: NSRect(
            x: topKnobCenter.x - topKnobDiameter / 2,
            y: topKnobCenter.y - topKnobDiameter / 2,
            width: topKnobDiameter,
            height: topKnobDiameter
        ))

        // 1. 上层开启态开关胶囊（实心填充 + 右侧旋钮；无 knobColor 时采用 evenOdd 镂空，避免破坏底层背景）
        let topPill = NSBezierPath(roundedRect: topRect, xRadius: pillH / 2, yRadius: pillH / 2)
        if knobColor == nil {
            topPill.append(topKnob)
            topPill.windingRule = .evenOdd
        }
        if let secondary {
            NSGraphicsContext.saveGraphicsState()
            topPill.addClip()
            NSGradient(starting: color, ending: secondary)?.draw(in: topRect, angle: isFlipped ? 90 : 270)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            color.setFill()
            topPill.fill()
        }
        if let knobColor {
            knobColor.setFill()
            topKnob.fill()
        }

        // 2. 下层遥测态开关胶囊（外框描边 + 左侧实心旋钮 + 右侧脉冲波形）
        let strokedRect = bottomRect.insetBy(dx: strokeW / 2, dy: strokeW / 2)
        let bottomRadius = max(0.5, strokedRect.height / 2)
        let bottomPill = NSBezierPath(roundedRect: strokedRect, xRadius: bottomRadius, yRadius: bottomRadius)
        bottomPill.lineWidth = strokeW
        color.setStroke()
        bottomPill.stroke()

        let bottomKnobDiameter = pillH * 0.46
        let bottomKnobCenter = NSPoint(x: bottomRect.minX + pillH / 2, y: bottomRect.midY)
        let bottomKnob = NSBezierPath(ovalIn: NSRect(
            x: bottomKnobCenter.x - bottomKnobDiameter / 2,
            y: bottomKnobCenter.y - bottomKnobDiameter / 2,
            width: bottomKnobDiameter,
            height: bottomKnobDiameter
        ))
        color.setFill()
        bottomKnob.fill()

        let waveStartX = bottomRect.minX + pillH * 0.92
        let waveEndX = bottomRect.maxX - pillH * 0.38
        if waveEndX > waveStartX + 2 {
            let waveBox = NSRect(x: waveStartX, y: bottomRect.minY, width: waveEndX - waveStartX, height: bottomRect.height)
            let wave = NSBezierPath()
            wave.move(to: pointIn(waveBox, nx: 0.0, nyFromTop: 0.50))
            wave.line(to: pointIn(waveBox, nx: 0.18, nyFromTop: 0.50))
            wave.line(to: pointIn(waveBox, nx: 0.36, nyFromTop: 0.66))
            wave.line(to: pointIn(waveBox, nx: 0.54, nyFromTop: 0.30))
            wave.line(to: pointIn(waveBox, nx: 0.72, nyFromTop: 0.70))
            wave.line(to: pointIn(waveBox, nx: 0.88, nyFromTop: 0.50))
            wave.line(to: pointIn(waveBox, nx: 1.0, nyFromTop: 0.50))
            wave.lineWidth = max(0.95, strokeW * 0.74)
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            (secondary ?? color).setStroke()
            wave.stroke()
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
