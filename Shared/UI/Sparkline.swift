import SwiftUI

/// A week of hourly usage as a neutral line over a faint area. Hours without a reading leave a
/// gap; 0–100% spans the full height. `level` marks the latest reading with a dot in its level's
/// colour: the only colour a chart carries. Leave it out for a stale reading.
struct Sparkline: View {
    var history: UsageHistory
    var tint: Color = TokenroomTokens.chartLine
    var lineWidth: CGFloat = 1.5
    var level: Color? = nil

    var body: some View {
        Canvas { context, size in
            let values = history.used
            guard values.count > 1 else { return }
            // Room for the latest reading's dot at the right edge, so it isn't cut in half.
            let radius = lineWidth * 1.8
            let step = (size.width - (level == nil ? 0 : radius)) / CGFloat(values.count - 1)
            for segment in Self.segments(values) {
                let points = segment.map { index, value in
                    CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(value) / 100))
                }
                guard let first = points.first, let last = points.last else { continue }
                var line = Path()
                line.addLines(points)
                var area = line
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(TokenroomTokens.chartArea))
                if points.count == 1 {
                    context.fill(Path(ellipseIn: CGRect(x: first.x - lineWidth, y: first.y - lineWidth, width: lineWidth * 2, height: lineWidth * 2)), with: .color(tint))
                } else {
                    context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            if let level, let (index, value) = Self.segments(values).last?.last {
                let point = CGPoint(x: CGFloat(index) * step, y: min(max(size.height * (1 - CGFloat(value) / 100), radius), size.height - radius))
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(level))
            }
        }
        .accessibilityHidden(true)
    }

    /// What the line shows, for VoiceOver: its highest hour and the latest.
    static func summary(_ history: UsageHistory) -> String {
        let used = history.points.map { $0.used }
        guard let latest = used.last, let highest = used.max() else { return "No readings" }
        return "Highest \(TokenroomFormat.percentText(highest))%, latest \(TokenroomFormat.percentText(latest))%"
    }

    /// Runs of consecutive readings, as (hour index, used %).
    static func segments(_ values: [UInt8?]) -> [[(Int, Double)]] {
        var segments: [[(Int, Double)]] = []
        var current: [(Int, Double)] = []
        for (index, value) in values.enumerated() {
            if let value {
                current.append((index, Double(value)))
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }
}
