import SwiftUI

struct ReviewGameSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// The game being reviewed (used for submission and club lookup).
    let gameID: UUID
    /// Display title — passed from the notification so we don't need the Game object in memory.
    let gameTitle: String
    /// Called after dismiss when the user taps "View Club".
    var onViewClub: ((Club) -> Void)? = nil

    @State private var selectedRating: Int = 0
    @State private var comment: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var submitted = false
    /// Resolved asynchronously on sheet open so it's ready when submit completes.
    @State private var resolvedClub: Club? = nil

    private let ratingLabels = ["", "Poor", "Fair", "Good", "Great", "Excellent"]

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.pageGradient.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        // Header
                        VStack(spacing: 6) {
                            Text(gameTitle)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Brand.ink)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 8)

                        if submitted {
                            submittedState
                        } else {
                            ratingSection
                            commentSection
                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(Brand.errorRed)
                                    .multilineTextAlignment(.center)
                            }
                            submitButton
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Brand.ink)
                }
            }
            .navigationTitle("Rate Your Session")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            // Resolve club in background so the "View Club" button is ready after submit
            resolvedClub = await appState.clubForGame(gameID: gameID)
        }
    }

    // MARK: - Rating Stars

    private var ratingSection: some View {
        VStack(spacing: 12) {
            Text("How was your experience?")
                .font(.headline)
                .foregroundStyle(Brand.ink)

            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        selectedRating = star
                    } label: {
                        Image(systemName: star <= selectedRating ? "star.fill" : "star")
                            .font(.system(size: 36))
                            .foregroundStyle(star <= selectedRating ? Brand.spicyOrange : Brand.softOutline)
                    }
                    .buttonStyle(.plain)
                }
            }

            if selectedRating > 0 {
                Text(ratingLabels[selectedRating])
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.spicyOrange)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .animation(.spring(response: 0.3), value: selectedRating)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 18, tint: Brand.cardBackground)
    }

    // MARK: - Comment

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leave a comment (optional)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
            TextField("What did you enjoy? Any feedback for the organiser?", text: $comment, axis: .vertical)
                .lineLimit(3...6)
                .font(.subheadline)
                .padding(12)
                .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
        .glassCard(cornerRadius: 18, tint: Brand.cardBackground)
    }

    // MARK: - Submit

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            Group {
                if isSubmitting {
                    ProgressView().tint(.white)
                } else {
                    Text("Submit Review")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white)
            .background(selectedRating > 0 ? Brand.emeraldAction : Brand.mutedText, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(selectedRating == 0 || isSubmitting)
    }

    // MARK: - Submitted State

    private var submittedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Brand.emeraldAction)
            Text("Thanks for your feedback!")
                .font(.title3.weight(.bold))
                .foregroundStyle(Brand.ink)
            Text("Your review helps improve the experience for everyone.")
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)

            if let club = resolvedClub, onViewClub != nil {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onViewClub?(club)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "building.2")
                            .font(.subheadline)
                        Text("View \(club.name)")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button("Done") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.mutedText)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 20, tint: Brand.cardBackground)
    }

    // MARK: - Submit Action

    private func submit() async {
        guard selectedRating > 0 else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try await appState.submitReview(
                gameID: gameID,
                rating: selectedRating,
                comment: comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : comment
            )
            // Ensure club is resolved (may already be from .task)
            if resolvedClub == nil {
                resolvedClub = await appState.clubForGame(gameID: gameID)
            }
            withAnimation { submitted = true }
        } catch SupabaseServiceError.httpStatus(409, _) {
            errorMessage = "You have already left a review for this session."
        } catch {
            errorMessage = "Couldn't submit your review. Please try again."
        }
        isSubmitting = false
    }
}
