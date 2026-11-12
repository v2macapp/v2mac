import Charts
import SwiftUI

/// The last minute of traffic, through the server (accent) and direct (green): download as soft
/// filled curves, upload as faint thin lines. A series with no traffic is left out.
/// New samples come in from the right, and the oldest fade out on the left.
struct TrafficSparkline: View {
    let samples: [ConnectionController.RateSample]

    /// How many samples fit across; `ConnectionController` keeps as many.
    private static let window = 60

    var body: some View {
        let points = Self.smoothed(samples)
        let last = points.last?.id ?? 0
        let series: [(value: (ConnectionController.RateSample) -> Double, color: Color, download: Bool)] = [
            ({ $0.directUp }, .green, false),
            ({ max($0.up - $0.directUp, 0) }, .accentColor, false),
            ({ $0.directDown }, .green, true),
            ({ max($0.down - $0.directDown, 0) }, .accentColor, true),
        ]
        let peak = max(points.map { p in series.map { $0.value(p) }.max() ?? 0 }.max() ?? 0, 1024)
        // One chart per series, stacked over each other on the same scale: simpler than
        // telling Charts which marks belong together.
        ZStack {
            ForEach(series.indices, id: \.self) { i in
                let line = series[i]
                if points.contains(where: { line.value($0) > 0 }) {
                    Chart(points) { point in
                        if line.download {
                            AreaMark(x: .value("Time", point.id), y: .value("Rate", line.value(point)))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(LinearGradient(colors: [line.color.opacity(0.28), line.color.opacity(0)], startPoint: .top, endPoint: .bottom))
                        }
                        LineMark(x: .value("Time", point.id), y: .value("Rate", line.value(point)))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: line.download ? 1.5 : 1, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(line.color.opacity(line.download ? 1 : 0.45))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartLegend(.hidden)
                    .chartXScale(domain: (last - Self.window + 1)...max(last, 1))
                    // Headroom, so the highest point does not touch the top edge.
                    .chartYScale(domain: 0...(peak * 1.2))
                }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25)], startPoint: .leading, endPoint: .trailing))
        // No animation on new samples: a 0.9 s spring every second kept Charts re-laying out all
        // the marks on every frame, ~65% CPU, even with every window closed.
        .accessibilityHidden(true)
        .help("Blue: through the server. Green: direct. Thin line: upload.")
    }

    /// Each point averaged with its neighbours: one-second samples of bursty traffic are spikes,
    /// and the graph is there to show the trend.
    private static func smoothed(_ samples: [ConnectionController.RateSample]) -> [ConnectionController.RateSample] {
        guard samples.count > 2 else { return samples }
        return samples.indices.map { index in
            let near = samples[max(index - 1, 0)...min(index + 1, samples.count - 1)]
            let count = Double(near.count)
            return .init(id: samples[index].id, down: near.reduce(0) { $0 + $1.down } / count, up: near.reduce(0) { $0 + $1.up } / count,
                         directDown: near.reduce(0) { $0 + $1.directDown } / count, directUp: near.reduce(0) { $0 + $1.directUp } / count)
        }
    }
}

/// "proxy / total": the part through the server a lighter grey than the whole. Never wraps.
struct ProxyOfTotal: View {
    let proxy: String
    let total: String

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: proxy).foregroundStyle(.secondary)
            Text(verbatim: " / \(total)").foregroundStyle(.tertiary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}
