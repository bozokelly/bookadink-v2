import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "figure.pickleball",
            iconColor: Brand.pineTeal,
            title: "Welcome to\nBook a Dink",
            body: "Find courts, join clubs, and book your next pickleball game — all in one place.",
            detail: nil
        ),
        OnboardingPage(
            icon: "mappin.and.ellipse",
            iconColor: Brand.emeraldAction,
            title: "Find Your Club",
            body: "Browse clubs near you, request membership, and connect with your local pickleball community.",
            detail: "Club admins approve members. Once approved you can book games, chat, and see the member directory."
        ),
        OnboardingPage(
            icon: "chart.line.uptrend.xyaxis",
            iconColor: Brand.softOrangeAccent,
            title: "Your DUPR Rating",
            body: "Some games require a DUPR rating to ensure fair matchups. Add yours to your profile — you can update it any time.",
            detail: "Don't have a DUPR yet? No problem — you can still join open games and add your rating later."
        )
    ]

    var body: some View {
        ZStack {
            Brand.pageGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // Page indicator
                HStack(spacing: 6) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Capsule()
                            .fill(i == currentPage ? Brand.pineTeal : Color.white.opacity(0.25))
                            .frame(width: i == currentPage ? 20 : 6, height: 6)
                            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: currentPage)
                    }
                }
                .padding(.top, 60)

                // Pages
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        pageView(page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: currentPage)

                // Buttons
                VStack(spacing: 12) {
                    if currentPage < pages.count - 1 {
                        Button {
                            withAnimation { currentPage += 1 }
                        } label: {
                            Text("Continue")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button("Skip") { onComplete() }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.5))
                    } else {
                        Button {
                            onComplete()
                        } label: {
                            Text("Get Started")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 48)
            }
        }
    }

    @ViewBuilder
    private func pageView(_ page: OnboardingPage) -> some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(page.iconColor.opacity(0.12))
                    .frame(width: 110, height: 110)
                Circle()
                    .strokeBorder(page.iconColor.opacity(0.25), lineWidth: 1)
                    .frame(width: 110, height: 110)
                Image(systemName: page.icon)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(page.iconColor)
            }
            .padding(.bottom, 36)

            // Title
            Text(page.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)

            // Body
            Text(page.body)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 32)

            // Detail callout
            if let detail = page.detail {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.pineTeal.opacity(0.8))
                        .padding(.top, 1)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineSpacing(3)
                }
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
                .padding(.horizontal, 28)
                .padding(.top, 24)
            }

            Spacer()
            Spacer()
        }
    }
}

private struct OnboardingPage {
    let icon: String
    let iconColor: Color
    let title: String
    let body: String
    let detail: String?
}

#Preview {
    OnboardingView(onComplete: {})
}
