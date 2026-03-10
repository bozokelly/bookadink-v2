import SwiftUI

enum AppTab: Hashable {
    case clubs
    case bookings
    case notifications
    case profile
}

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: AppTab = .clubs

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ClubsListView(clubs: appState.clubs)
            }
            .tabItem {
                Label("Clubs", systemImage: "building.2")
            }
            .tag(AppTab.clubs)

            NavigationStack {
                BookingsListView()
            }
            .tabItem {
                Label("Bookings", systemImage: "calendar")
            }
            .tag(AppTab.bookings)

            NavigationStack {
                NotificationsView()
            }
            .tabItem {
                Label("Notifications", systemImage: "bell")
            }
            .badge(appState.unreadNotificationCount > 0 ? appState.unreadNotificationCount : 0)
            .tag(AppTab.notifications)

            NavigationStack {
                ProfileDashboardView()
            }
            .tabItem {
                Label("Profile", systemImage: "person.crop.circle")
            }
            .tag(AppTab.profile)
        }
        .tint(Brand.brandPrimary)
    }
}


// MARK: - Edit Profile Sheet

struct EditProfileSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    // Personal Info
    @State private var fullName = ""
    @State private var phone = ""
    @State private var dateOfBirth: Date? = nil
    @State private var showDOBPicker = false
    @State private var duprRatingText = ""
    @State private var personalSaved = false

    // Emergency Contact
    @State private var emergencyName = ""
    @State private var emergencyPhone = ""
    @State private var emergencySaved = false

    // Password
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        personalInfoCard
                        emergencyContactCard
                        changePasswordCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { populateFields() }
        }
    }

    // MARK: Personal Info Card

    private var personalInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Personal Info", systemImage: "person.circle")
                .font(.headline.weight(.bold))
                .foregroundStyle(Brand.ink)

            editField(label: "Full Name", placeholder: "Your full name", text: $fullName)
            editField(label: "Mobile Number", placeholder: "e.g. 0412 345 678", text: $phone)
                .keyboardType(.phonePad)

            // Date of Birth
            VStack(alignment: .leading, spacing: 6) {
                Text("Date of Birth")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.mutedText)
                Button {
                    showDOBPicker.toggle()
                } label: {
                    HStack {
                        Text(dateOfBirth.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Not set")
                            .foregroundStyle(dateOfBirth == nil ? Brand.mutedText : Brand.ink)
                        Spacer()
                        Image(systemName: "calendar")
                            .foregroundStyle(Brand.pineTeal)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                if showDOBPicker {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { dateOfBirth ?? Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date() },
                            set: { dateOfBirth = $0 }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                }
            }

            editField(label: "DUPR Rating", placeholder: "e.g. 3.52", text: $duprRatingText)
                .keyboardType(.decimalPad)

            if let error = appState.profileSaveErrorMessage, !error.isEmpty, !personalSaved {
                feedbackText(error, isError: true)
            } else if personalSaved {
                feedbackText("Personal info saved.", isError: false)
            }

            saveButton(title: "Save Changes", busy: appState.isSavingProfile) {
                Task { await savePersonalInfo() }
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    // MARK: Emergency Contact Card

    private var emergencyContactCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Emergency Contact", systemImage: "shield.lefthalf.filled")
                .font(.headline.weight(.bold))
                .foregroundStyle(Brand.ink)

            Text("This information will be available to club admins in case of an emergency.")
                .font(.caption)
                .foregroundStyle(Brand.mutedText)

            editField(label: "Contact Name", placeholder: "e.g. Jane Kelly", text: $emergencyName)
            editField(label: "Contact Phone", placeholder: "e.g. 0412 345 678", text: $emergencyPhone)
                .keyboardType(.phonePad)

            if emergencySaved {
                feedbackText("Emergency contact saved.", isError: false)
            }

            saveButton(title: "Save Emergency Contact", busy: appState.isSavingProfile) {
                Task { await saveEmergencyContact() }
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    // MARK: Change Password Card

    private var changePasswordCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Change Password", systemImage: "lock")
                .font(.headline.weight(.bold))
                .foregroundStyle(Brand.ink)

            VStack(alignment: .leading, spacing: 6) {
                Text("New Password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.mutedText)
                SecureField("Enter new password", text: $newPassword)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Confirm Password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.mutedText)
                SecureField("Confirm new password", text: $confirmPassword)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
            }

            if let msg = appState.passwordUpdateMessage {
                feedbackText(msg, isError: !msg.contains("successfully"))
            }

            saveButton(title: "Update Password", busy: appState.isUpdatingPassword) {
                Task {
                    await appState.updatePassword(newPassword: newPassword, confirmPassword: confirmPassword)
                    if appState.passwordUpdateMessage?.contains("successfully") == true {
                        newPassword = ""
                        confirmPassword = ""
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    // MARK: Helpers

    private func editField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.mutedText)
            TextField(placeholder, text: text)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private func feedbackText(_ message: String, isError: Bool) -> some View {
        Text(message)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isError ? Brand.errorRed : Brand.pineTeal)
    }

    private func saveButton(title: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                Text(title).fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Brand.emeraldAction, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func populateFields() {
        guard let profile = appState.profile else { return }
        fullName = profile.fullName
        phone = profile.phone ?? ""
        dateOfBirth = profile.dateOfBirth
        duprRatingText = profile.duprRating.map { String(format: "%g", $0) } ?? ""
        emergencyName = profile.emergencyContactName ?? ""
        emergencyPhone = profile.emergencyContactPhone ?? ""
        appState.profileSaveErrorMessage = nil
        appState.passwordUpdateMessage = nil
    }

    private func savePersonalInfo() async {
        let duprValue = duprRatingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : Double(duprRatingText.trimmingCharacters(in: .whitespacesAndNewlines))
        let phoneTrimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        personalSaved = false
        await appState.saveProfilePersonalInfo(
            fullName: fullName,
            phone: phoneTrimmed.isEmpty ? nil : phoneTrimmed,
            dateOfBirth: dateOfBirth,
            duprRating: duprValue
        )
        if appState.profileSaveErrorMessage == nil {
            personalSaved = true
        }
    }

    private func saveEmergencyContact() async {
        let nameTrimmed = emergencyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneTrimmed = emergencyPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        emergencySaved = false
        await appState.saveEmergencyContact(
            name: nameTrimmed.isEmpty ? nil : nameTrimmed,
            phone: phoneTrimmed.isEmpty ? nil : phoneTrimmed
        )
        if appState.profileSaveErrorMessage == nil {
            emergencySaved = true
        }
    }
}
