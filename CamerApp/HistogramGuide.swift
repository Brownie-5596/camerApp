import SwiftUI

/// The ✓ / warning under the histogram.
struct ExposureCheck: View {
    let verdict: HistogramReading.Verdict
    let theme: Theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(label)
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.55), in: Capsule())
    }

    private var symbol: String {
        switch verdict {
        case .good: return "checkmark.circle.fill"
        case .tooBright: return "exclamationmark.triangle.fill"
        case .tooDark: return "moon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var label: String {
        switch verdict {
        case .good: return "Exposure OK"
        case .tooBright: return "Too bright"
        case .tooDark: return "Too dark"
        case .unknown: return "—"
        }
    }

    private var color: Color {
        if theme.redMode { return verdict == .good ? theme.accent : theme.primary }
        switch verdict {
        case .good: return .green
        case .tooBright: return .orange
        case .tooDark: return .yellow
        case .unknown: return .gray
        }
    }
}

/// How to read the histogram, with examples.
struct HistogramGuide: View {
    let theme: Theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("The histogram is a bar chart of how bright your picture is. Left is black, right is white, and the height shows how much of the picture is at that brightness.")
                        .font(.callout)

                    example(title: "Good", verdict: .good, bins: Self.shape(center: 0.45, width: 0.22),
                            text: "A hill spread across the middle, not piled up against either edge. You'll see the green ✓.")
                    example(title: "Too bright", verdict: .tooBright, bins: Self.shape(center: 0.92, width: 0.12, clip: true),
                            text: "Bunched against the right edge: bright areas are pure white and their detail is gone for good. Use a faster shutter, lower ISO, or −EV.")
                    example(title: "Too dark", verdict: .tooDark, bins: Self.shape(center: 0.03, width: 0.04),
                            text: "Squashed against the left edge: shadows are pure black and noisy when brightened. Use a slower shutter, higher ISO, or +EV.")
                    example(title: "Night sky (good)", verdict: .good, bins: Self.shape(center: 0.22, width: 0.12),
                            text: "At night the hill sits in the left third, but it should still be clear of the left edge. A few bright stars or city lights touching the right side are fine.")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tips").font(.headline)
                        Text("• The check is a guide, not a rule: snow scenes are meant to be bright and night scenes dark.")
                        Text("• For long exposures, the histogram shows the finished photo, not one preview frame.")
                        Text("• Turn on Clipping warning in Settings to see blown-out areas flash pink on the preview.")
                        Text("• Tap the histogram any time to open this guide.")
                    }
                    .font(.footnote)
                }
                .padding(20)
            }
            .foregroundStyle(theme.primary)
            .background(Color.black)
            .navigationTitle("Reading the histogram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func example(title: String, verdict: HistogramReading.Verdict, bins: [Float], text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HistogramView(bins: bins, color: theme.primary)
                ExposureCheck(verdict: verdict, theme: theme)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.footnote).foregroundStyle(theme.secondary)
            }
        }
    }

    /// A bell-shaped example histogram.
    private static func shape(center: Float, width: Float, clip: Bool = false) -> [Float] {
        (0..<64).map { i in
            let x = Float(i) / 63
            var v = expf(-powf((x - center) / width, 2))
            if clip && i == 63 { v = 1 }
            return v
        }
    }
}
