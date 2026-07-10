import SwiftUI

/// E3 · Reference Match Meter — how close is your mix to a track you love?
/// One row per measured dimension, each with a score bar and a concrete tip.
struct ReferenceMatchView: View {
    @Environment(\.dismiss) private var dismiss
    let result: ReferenceMatchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "scope").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reference Match").font(.headline)
                    Text("vs \(result.referenceName)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int((result.overall * 100).rounded()))%")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(color(for: result.overall))
                    Text("match").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 12)

            Divider()

            VStack(spacing: 14) {
                ForEach(result.dimensions) { dim in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(dim.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("you \(dim.yours)").font(.caption).foregroundStyle(.primary)
                            Text("·").foregroundStyle(.secondary)
                            Text("ref \(dim.reference)").font(.caption).foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule()
                                    .fill(color(for: dim.score))
                                    .frame(width: max(6, geo.size.width * dim.score))
                            }
                        }
                        .frame(height: 6)
                        if let tip = dim.tip {
                            Label(tip, systemImage: "lightbulb")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(18)

            Divider()

            HStack {
                Text("Measured from your current mix — re-run after changes.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 470)
    }

    private func color(for score: Double) -> Color {
        score >= 0.8 ? .green : score >= 0.55 ? .orange : .red
    }
}
