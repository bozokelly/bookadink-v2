import SwiftUI

struct AuthWelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var email = ""
    @State private var password = ""
    @State private var authMode: AuthMode = .signIn

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 10) {
                Text("Book a dink")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.primaryText)

                Text("Find clubs, join your community, and book your next game.")
                    .font(.headline)
                    .foregroundStyle(Brand.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 14) {
                Picker("Auth Mode", selection: $authMode) {
                    ForEach(AuthMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(4)
                .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 12) {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(Brand.pineTeal)
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                }
                .padding()
                .glassCard(cornerRadius: 18, tint: Brand.cardBackground)

                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Brand.pineTeal)
                    SecureField("Password", text: $password)
                }
                .padding()
                .glassCard(cornerRadius: 18, tint: Brand.cardBackground)

                Button {
                    let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    Task {
                        switch authMode {
                        case .signIn:
                            await appState.signIn(email: normalizedEmail, password: password)
                        case .signUp:
                            await appState.signUp(email: normalizedEmail, password: password)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if appState.isAuthenticating {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(appState.isAuthenticating ? "Please wait..." : authMode.buttonTitle)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(appState.isAuthenticating || !canSubmit)
                .opacity((appState.isAuthenticating || !canSubmit) ? 0.6 : 1)
                .buttonStyle(.plain)
                .actionBorder(cornerRadius: 16, color: Brand.softOutline)

                if let info = appState.authInfoMessage, !info.isEmpty {
                    Text(info)
                        .font(.footnote)
                        .foregroundStyle(Brand.pineTeal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error = appState.authErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            }
            .padding(18)
            .glassCard(cornerRadius: 26, tint: Brand.cardBackground)

            Text("Email/password sign in is enabled.")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6
    }
}

private enum AuthMode: CaseIterable, Identifiable {
    case signIn
    case signUp

    var id: String { title }

    var title: String {
        switch self {
        case .signIn: return "Sign In"
        case .signUp: return "Sign Up"
        }
    }

    var buttonTitle: String {
        switch self {
        case .signIn: return "Sign In"
        case .signUp: return "Create Account"
        }
    }
}

#Preview {
    AuthWelcomeView()
        .environmentObject(AppState())
        .background(Brand.pageGradient)
}
