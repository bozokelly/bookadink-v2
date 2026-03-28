import SwiftUI

struct DUPRHistoryDetailView: View {
    @EnvironmentObject private var appState: AppState

    private var sorted: [DUPREntry] {
        appState.duprHistory.sorted { $0.recordedAt > $1.recordedAt }
    }

    var body: some View {
        ZStack {
            Brand.pageGradient.ignoresSafeArea()
            if sorted.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 40))
                        .foregroundStyle(Brand.pineTeal)
                    Text("No history yet")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Update your DUPR rating to start tracking.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(sorted.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(String(format: "%.3f", entry.rating))
                                        .font(.system(.title3, design: .rounded).weight(.bold))
                                        .foregroundStyle(Brand.ink)
                                    if let ctx = entry.context {
                                        Text(ctx)
                                            .font(.caption)
                                            .foregroundStyle(Brand.mutedText)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    if let prev = sorted.dropFirst(index + 1).first {
                                        let delta = entry.rating - prev.rating
                                        let sign = delta >= 0 ? "+" : ""
                                        Text("\(sign)\(String(format: "%.3f", delta))")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(delta >= 0 ? Brand.emeraldAction : Brand.errorRed)
                                    }
                                    Text(entry.recordedAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption)
                                        .foregroundStyle(Brand.mutedText)
                                }
                            }
                            .padding(14)
                            .glassCard(cornerRadius: 16, tint: Brand.cardBackground)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle("DUPR History")
        .navigationBarTitleDisplayMode(.inline)
    }
}
