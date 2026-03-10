import SwiftUI

struct LoadingScreenView: View {
    @State private var animating = false
    @State private var breathing = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.26, blue: 0.42),
                    Color(red: 0.13, green: 0.20, blue: 0.35),
                    Color(red: 0.10, green: 0.16, blue: 0.28),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Image("app_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .scaleEffect(breathing ? 1.04 : 1.0)
                    .animation(
                        .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
                        value: breathing
                    )

                Spacer().frame(height: 48)

                VStack(spacing: 14) {
                    Text("Pickling...")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white)
                        .tracking(2)

                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(Color.white.opacity(0.7))
                                .frame(width: 8, height: 8)
                                .scaleEffect(animating ? 1.4 : 1.0)
                                .opacity(animating ? 1.0 : 0.4)
                                .animation(
                                    .easeInOut(duration: 0.5)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.18),
                                    value: animating
                                )
                        }
                    }
                }

                Spacer()
            }
        }
        .onAppear {
            animating = true
            breathing = true
        }
    }
}

#Preview {
    LoadingScreenView()
}
