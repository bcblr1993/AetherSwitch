import SwiftUI

/// 1. 圆环仪表盘（单色或双色环）
public struct RingGaugeView: View {
    let title: String
    let valueString: String
    let percent: Double
    let secondaryPercent: Double?
    let primaryColor: Color
    let secondaryColor: Color?
    let size: CGFloat

    public init(
        title: String = "",
        valueString: String,
        percent: Double,
        secondaryPercent: Double? = nil,
        primaryColor: Color = .blue,
        secondaryColor: Color? = nil,
        size: CGFloat = 64
    ) {
        self.title = title
        self.valueString = valueString
        self.percent = percent
        self.secondaryPercent = secondaryPercent
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.size = size
    }

    public var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // 底环
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 5.5)

                // 次级环（例如系统负载）
                if let sec = secondaryPercent, let secColor = secondaryColor {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(1.0, max(0.0, sec / 100.0))))
                        .stroke(secColor, style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }

                // 主环（例如总利用率或用户负载）
                Circle()
                    .trim(from: 0, to: CGFloat(min(1.0, max(0.0, percent / 100.0))))
                    .stroke(primaryColor, style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: percent)

                // 中间文字
                Text(valueString)
                    .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .monospacedDigit()
            }
            .frame(width: size, height: size)

            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// 2. 内存压力半圆弧仪表盘（绿/黄/红 + 正常/警告指示）
public struct PressureGaugeView: View {
    let statusText: String
    let percent: Double
    let size: CGFloat

    public init(statusText: String, percent: Double, size: CGFloat = 64) {
        self.statusText = statusText
        self.percent = percent
        self.size = size
    }

    public var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // 半圆底弧
                Circle()
                    .trim(from: 0.5, to: 1.0)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [.green, .yellow, .red]),
                            center: .center,
                            startAngle: .degrees(180),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: size, height: size)

                // 指针位置
                let angle = 180.0 + (min(100.0, max(0.0, percent)) / 100.0) * 180.0
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: size * 0.32)
                    .offset(y: -size * 0.16)
                    .rotationEffect(.degrees(angle - 270))

                Text(statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .offset(y: size * 0.24)
            }
            .frame(width: size, height: size * 0.7)
            .clipped()
        }
    }
}

/// 3. 单向平滑波形图（Sparkline Area Chart）
public struct WaveformChartView: View {
    let data: [Double]
    let lineColor: Color
    let height: CGFloat

    public init(data: [Double], lineColor: Color = .blue, height: CGFloat = 52) {
        self.data = data.isEmpty ? [0] : data
        self.lineColor = lineColor
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            let points = normalizePoints(in: geo.size)
            ZStack {
                // 填充区域
                Path { path in
                    guard points.count > 1 else { return }
                    path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                    path.addLine(to: points[0])
                    for pt in points.dropFirst() {
                        path.addLine(to: pt)
                    }
                    path.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [lineColor.opacity(0.4), lineColor.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // 顶端线条
                Path { path in
                    guard points.count > 1 else { return }
                    path.move(to: points[0])
                    for pt in points.dropFirst() {
                        path.addLine(to: pt)
                    }
                }
                .stroke(lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func normalizePoints(in size: CGSize) -> [CGPoint] {
        guard data.count > 1 else { return [CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] }
        let stepX = size.width / CGFloat(data.count - 1)
        var points: [CGPoint] = []
        for (i, val) in data.enumerated() {
            let clamped = max(0.0, min(100.0, val))
            let y = size.height - (CGFloat(clamped / 100.0) * size.height)
            points.append(CGPoint(x: CGFloat(i) * stepX, y: max(2, min(size.height - 2, y))))
        }
        return points
    }
}

/// 4. 磁盘对称双向流动波形图（上写入红，下读取蓝，对应图 4）
public struct BidirectionalDiskWaveformView: View {
    let writeData: [Double]
    let readData: [Double]
    let height: CGFloat

    public init(writeData: [Double], readData: [Double], height: CGFloat = 52) {
        self.writeData = writeData.isEmpty ? [1] : writeData
        self.readData = readData.isEmpty ? [1] : readData
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            let midY = geo.size.height / 2.0
            ZStack {
                // 中轴虚线
                Path { path in
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: geo.size.width, y: midY))
                }
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // 上半部分：写入波形 (红色)
                Path { path in
                    let step = geo.size.width / CGFloat(max(1, writeData.count - 1))
                    path.move(to: CGPoint(x: 0, y: midY))
                    for (i, val) in writeData.enumerated() {
                        let h = CGFloat(min(1.0, val / 15.0)) * (midY - 4)
                        path.addLine(to: CGPoint(x: CGFloat(i) * step, y: midY - h))
                    }
                    path.addLine(to: CGPoint(x: geo.size.width, y: midY))
                    path.closeSubpath()
                }
                .fill(Color.red.opacity(0.4))

                // 下半部分：读取波形 (蓝色)
                Path { path in
                    let step = geo.size.width / CGFloat(max(1, readData.count - 1))
                    path.move(to: CGPoint(x: 0, y: midY))
                    for (i, val) in readData.enumerated() {
                        let h = CGFloat(min(1.0, val / 15.0)) * (midY - 4)
                        path.addLine(to: CGPoint(x: CGFloat(i) * step, y: midY + h))
                    }
                    path.addLine(to: CGPoint(x: geo.size.width, y: midY))
                    path.closeSubpath()
                }
                .fill(Color.blue.opacity(0.45))
            }
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

/// 5. 核心利用率柱状条群（能效核心青色 + 性能核心紫色，对应图 1）
public struct MultiCoreBarsView: View {
    let coreLoads: [Double]
    let eCoreCount: Int

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<coreLoads.count, id: \.self) { idx in
                let isECore = idx < eCoreCount
                let load = coreLoads[idx]
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isECore ? Color.teal : Color.purple)
                            .frame(height: max(3, geo.size.height * CGFloat(load / 100.0)))
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: load)
                    }
                }
            }
        }
        .frame(height: 28)
    }
}
