import SwiftUI

/// A/B single-elimination bracket over the current Suno candidates.
/// Each head-to-head pick trains the Taste Profile; the last one standing
/// is the champion, which the user adds to the timeline.
struct TournamentView: View {
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var preview: PreviewPlayer
    @EnvironmentObject var taste: TasteEngine
    @Environment(\.dismiss) private var dismiss

    // Snapshot of the tray on appear.
    @State private var entrants: [CandidateAsset] = []

    // Bracket state.
    @State private var queue: [CandidateAsset] = []
    @State private var winners: [CandidateAsset] = []
    @State private var round: Int = 1
    @State private var comparisons: Int = 0

    // Champion screen state.
    @State private var champion: CandidateAsset? = nil
    @State private var splitToggle: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Label("Taste Tournament", systemImage: "trophy").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if entrants.count < 2 {
                emptyState
            } else if let champ = champion {
                championScreen(champ)
            } else if queue.count >= 2 {
                matchScreen
            } else {
                // Should never happen when setup is correct, but guard anyway.
                emptyState
            }
        }
        .frame(width: 560)
        .onAppear {
            entrants = project.candidates
            if entrants.count >= 2 {
                startRound(entrants)
            }
        }
        .onDisappear {
            preview.stop()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "trophy")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Generate at least 2 variants to run a tournament.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }

    // MARK: - Match screen

    private var matchScreen: some View {
        let a = queue[0]
        let b = queue[1]
        let matchesLeft = matchesLeftThisRound()

        return VStack(spacing: 16) {
            Text("Round \(round) · \(matchesLeft) to go")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(alignment: .top, spacing: 0) {
                candidateCard(a) { pick(winner: a, loser: b) }

                Text("vs")
                    .font(.title3.weight(.light))
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
                    .padding(.top, 28)

                candidateCard(b) { pick(winner: b, loser: a) }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 20)
    }

    private func candidateCard(_ candidate: CandidateAsset, onPick: @escaping () -> Void) -> some View {
        let isPlaying = preview.playingID == candidate.id

        return VStack(spacing: 12) {
            // Play/stop button
            Button {
                preview.toggle(id: candidate.id, url: candidate.asset.url)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)

            // Title + duration
            VStack(spacing: 3) {
                Text(candidate.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(timecode(candidate.asset.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Pick button
            Button("Pick this one") { onPick() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Champion screen

    private func championScreen(_ champ: CandidateAsset) -> some View {
        let isPlaying = preview.playingID == champ.id

        return VStack(spacing: 18) {
            Text("Your pick")
                .font(.title2.weight(.semibold))

            VStack(spacing: 10) {
                Button {
                    preview.toggle(id: champ.id, url: champ.asset.url)
                } label: {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)

                Text(champ.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(timecode(champ.asset.duration))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .padding(.horizontal, 24)

            Text("Trained your taste from \(comparisons) comparison\(comparisons == 1 ? "" : "s").")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Split into stems (separate tracks)", isOn: $splitToggle)
                .font(.callout)

            HStack(spacing: 12) {
                Button {
                    project.concludeTournament(champion: champ, asStems: splitToggle)
                    dismiss()
                } label: {
                    Label("Add to timeline", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderedProminent)

                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Bracket logic

    /// Number of complete matches left this round (including the current one).
    private func matchesLeftThisRound() -> Int {
        (queue.count) / 2
    }

    private func startRound(_ pool: [CandidateAsset]) {
        queue = pool
        winners = []
    }

    private func pick(winner: CandidateAsset, loser: CandidateAsset) {
        project.recordTournamentPick(winner: winner, loser: loser)
        // Eliminate the loser from the tray immediately — its comparison signal is already
        // recorded, so it can't be re-added later at full +1.0 taste weight, and reopening
        // the tournament won't replay this matchup (the local bracket runs off `queue`/
        // `winners`/`entrants`, which are untouched by mutating project.candidates here).
        project.removeCandidate(loser)
        comparisons += 1
        preview.stop()

        // Remove this match from the queue.
        queue.removeFirst(2)
        winners.append(winner)

        // Odd bye: if one entrant is stranded, advance it automatically.
        if queue.count == 1 {
            winners.append(queue.removeFirst())
        }

        // Round over?
        if queue.isEmpty {
            if winners.count == 1 {
                // We have a champion.
                champion = winners[0]
            } else {
                // Start the next round.
                round += 1
                startRound(winners)
            }
        }
    }
}
