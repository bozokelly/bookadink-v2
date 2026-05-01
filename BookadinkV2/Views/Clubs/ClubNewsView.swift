import SwiftUI
import PhotosUI
import UIKit

struct ClubNewsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    let club: Club
    let isClubModerator: Bool

    @State private var postText = ""
    @State private var isAnnouncementPost = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var draftImages: [DraftNewsImage] = []
    @State private var showAttachmentOptions = false
    @State private var showCamera = false
    @State private var deletingPost: ClubNewsPost?
    @State private var deletingCommentTarget: ClubNewsCommentDeletionTarget?
    @State private var editingPost: ClubNewsPost?
    @State private var reportTarget: ClubNewsReportTarget?
    @State private var showModerationQueue = false
    @State private var hiddenPostIDs: Set<UUID> = []
    @State private var localInfoMessage: String?
    @State private var mentionCandidates: [ClubDirectoryMember] = []

    private var canPost: Bool {
        guard appState.authUserID != nil else { return false }
        if isClubModerator { return true }
        switch appState.membershipState(for: club) {
        case .approved, .unknown:
            return true
        case .none, .pending, .rejected:
            return false
        }
    }

    private var posts: [ClubNewsPost] {
        appState.clubNewsPosts(for: club).filter { !hiddenPostIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {

            if let error = appState.clubNewsError(for: club), !error.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(AppCopy.friendlyError(error))
                    Spacer(minLength: 0)
                    Button("Retry") {
                        Task { await refreshVisibleChat() }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.errorRed)
                }
                .font(.footnote)
                .foregroundStyle(Brand.errorRed)
                .appErrorCardStyle(cornerRadius: 12)
            }

            if let localInfoMessage, !localInfoMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.emeraldAction)
                    Text(localInfoMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Brand.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Brand.softOutline, lineWidth: 1)
                )
            }

            if let pushError = appState.remotePushRegistrationErrorMessage, !pushError.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                    Text(AppCopy.friendlyError(pushError))
                    Spacer(minLength: 0)
                }
                .font(.footnote)
                .foregroundStyle(Brand.errorRed)
                .appErrorCardStyle(cornerRadius: 12)
            }

            composerCard

            if appState.isLoadingClubNews(for: club) && posts.isEmpty {
                ProgressView("Loading club chat...")
                    .tint(Brand.pineTeal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if posts.isEmpty {
                emptyState
            } else {
                ForEach(posts) { post in
                    ClubNewsPostCard(
                        club: club,
                        post: post,
                        isClubModerator: isClubModerator,
                        onLike: {
                            Task { await appState.toggleClubNewsLike(for: club, post: post) }
                        },
                        onComment: { text, parentID in
                            Task {
                                await appState.addClubNewsComment(for: club, post: post, content: text, parentCommentID: parentID)
                            }
                        },
                        onDelete: {
                            deletingPost = post
                        },
                        onEdit: {
                            editingPost = post
                        },
                        onHidePost: {
                            hiddenPostIDs.insert(post.id)
                            localInfoMessage = "Post hidden from your view."
                        },
                        onReportPost: {
                            reportTarget = .post(post)
                        },
                        onDeleteComment: { comment in
                            deletingCommentTarget = ClubNewsCommentDeletionTarget(post: post, comment: comment)
                        },
                        onReportComment: { comment in
                            reportTarget = .comment(comment)
                        }
                    )
                    .environmentObject(appState)
                }
            }
          }
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .padding(.bottom, 32)
        }
        .onChange(of: selectedPhotoItems.count) { _, _ in
            Task { await loadPickedPhotos(selectedPhotoItems) }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 4,
            matching: .images
        )
        .sheet(isPresented: $showCamera) {
            CameraCaptureView { image in
                if let image {
                    appendCameraImage(image)
                }
            }
        }
        .confirmationDialog(
            "Add Photo",
            isPresented: $showAttachmentOptions,
            titleVisibility: .visible
        ) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") {
                    showCamera = true
                }
            }
            Button("Choose from Photos") {
                showPhotoPicker = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add up to 4 photos to your club chat post.")
        }
        .confirmationDialog(
            "Delete Post?",
            isPresented: Binding(
                get: { deletingPost != nil },
                set: { if !$0 { deletingPost = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let post = deletingPost {
                Button("Delete Post", role: .destructive) {
                    Task {
                        await appState.deleteClubNewsPost(for: club, post: post)
                        deletingPost = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                deletingPost = nil
            }
        } message: {
            Text("This will remove the post and its discussion from Club Chat.")
        }
        .confirmationDialog(
            "Delete Comment?",
            isPresented: Binding(
                get: { deletingCommentTarget != nil },
                set: { if !$0 { deletingCommentTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = deletingCommentTarget {
                Button("Delete Comment", role: .destructive) {
                    Task {
                        await appState.deleteClubNewsComment(for: club, post: target.post, comment: target.comment)
                        deletingCommentTarget = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                deletingCommentTarget = nil
            }
        } message: {
            Text("This comment will be removed from the post.")
        }
        .confirmationDialog(
            "Report",
            isPresented: Binding(
                get: { reportTarget != nil },
                set: { if !$0 { reportTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Spam") { submitReport(reason: "spam") }
            Button("Abusive") { submitReport(reason: "abusive") }
            Button("Inappropriate") { submitReport(reason: "inappropriate") }
            Button("Other") { submitReport(reason: "other") }
            Button("Cancel", role: .cancel) { reportTarget = nil }
        } message: {
            Text("Send this to club moderators for review.")
        }
        .sheet(item: $editingPost) { post in
            ClubNewsEditPostSheet(post: post) { content, retainedURLs, newUploads in
                let success = await appState.editClubNewsPost(
                    for: club,
                    post: post,
                    content: content,
                    appendedImages: newUploads,
                    retainedImageURLs: retainedURLs
                )
                if success {
                    editingPost = nil
                }
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showModerationQueue) {
            ClubNewsModerationQueueSheet(club: club)
                .environmentObject(appState)
        }
        .task(id: club.id) {
            await appState.prepareClubChatPushNotificationsIfNeeded()
            appState.startClubChatRealtime(for: club, includeModeration: isClubModerator)
            if appState.clubNewsPosts(for: club).isEmpty {
                await appState.refreshClubNews(for: club)
            }
            if isClubModerator {
                await appState.refreshClubNewsModerationReports(for: club)
            }
        }
        .onDisappear {
            appState.stopClubChatRealtime(for: club)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await refreshVisibleChat() }
        }
        .onChange(of: isClubModerator) { _, newValue in
            appState.stopClubChatRealtime(for: club)
            appState.startClubChatRealtime(for: club, includeModeration: newValue)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !hiddenPostIDs.isEmpty {
                    Button("Show Hidden") {
                        hiddenPostIDs.removeAll()
                        localInfoMessage = "Hidden posts restored."
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                }

                if isClubModerator {
                    Button {
                        showModerationQueue = true
                    } label: {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.primaryText)
                    }
                    .accessibilityLabel("Open moderation reports")
                }

                Button {
                    Task { await refreshVisibleChat() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                }
                .accessibilityLabel("Refresh club chat")
            }
        }
    }


    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                let name = appState.profile?.fullName ?? ""
                Circle()
                    .fill(AvatarGradients.resolveGradient(forKey: appState.profile?.avatarColorKey))
                    .overlay(
                        Text(chatInitials(name))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 6) {
                    if !canPost {
                        Text(appState.authUserID == nil
                             ? "Sign in to post in Club Chat."
                             : "Join the club to post in Club Chat.")
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                    }
                    TextField("Share an update… use @ to mention a member", text: $postText, axis: .vertical)
                        .lineLimit(1...5)
                        .textInputAutocapitalization(.sentences)
                        .disabled(!canPost || appState.isPostingClubNews(for: club))
                        .font(.body)
                        .onChange(of: postText) { _, newText in
                            refreshMentionCandidates(for: newText)
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if !draftImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draftImages) { attachment in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: attachment.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Button {
                                    draftImages.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, Brand.spicyOrange)
                                        .font(.title3)
                                }
                                .offset(x: 6, y: -6)
                            }
                            .padding(.top, 6)
                            .padding(.trailing, 4)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 6)
            }

            if !mentionCandidates.isEmpty {
                Divider()
                mentionCandidateList(mentionCandidates) { member in
                    guard let (_, atIdx) = activeMentionQuery(in: postText) else { return }
                    postText = String(postText[..<atIdx]) + "@\(member.name) "
                    mentionCandidates = []
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    showAttachmentOptions = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Photo")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Brand.pineTeal)
                }
                .buttonStyle(.plain)
                .disabled(!canPost || appState.isPostingClubNews(for: club))
                .accessibilityLabel("Add photo to post")

                if isClubModerator {
                    Button {
                        isAnnouncementPost.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "megaphone.fill")
                            if !isAnnouncementPost {
                                Text("Announce")
                                    .font(.caption.weight(.bold))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(isAnnouncementPost ? .white : Brand.spicyOrange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            isAnnouncementPost ? Brand.spicyOrange : Brand.spicyOrange.opacity(0.15),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canPost || appState.isPostingClubNews(for: club))
                }

                Spacer()

                Text("\(draftImages.count)/4")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)

                Button {
                    Task { await submitPost() }
                } label: {
                    Group {
                        if appState.isPostingClubNews(for: club) {
                            ProgressView().tint(.white).controlSize(.small)
                        } else {
                            Text(isAnnouncementPost ? "Announce" : "Post")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Brand.pineTeal, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canPost || appState.isPostingClubNews(for: club) || (postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftImages.isEmpty))
                .opacity((!canPost || appState.isPostingClubNews(for: club) || (postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftImages.isEmpty)) ? 0.6 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(Brand.pineTeal)
            Text("No posts yet")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Be the first to share an update.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    @MainActor
    private func loadPickedPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var newDrafts: [DraftNewsImage] = []

        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                newDrafts.append(DraftNewsImage(image: image))
            }
        }

        if !newDrafts.isEmpty {
            for draft in newDrafts where draftImages.count < 4 {
                draftImages.append(draft)
            }
        }
        selectedPhotoItems = []
    }

    @MainActor
    private func appendCameraImage(_ image: UIImage) {
        guard draftImages.count < 4 else { return }
        draftImages.append(DraftNewsImage(image: image))
    }

    private func submitPost() async {
        let uploads = draftImages.compactMap { $0.uploadPayload }
        let announce = isAnnouncementPost
        let success = await appState.createClubNewsPost(for: club, content: postText, images: uploads, isAnnouncement: announce)
        if success {
            postText = ""
            draftImages = []
            selectedPhotoItems = []
            isAnnouncementPost = false
        }
    }

    private func submitReport(reason: String) {
        guard let target = reportTarget else { return }
        let details = "Submitted from iOS Club Chat"
        Task {
            switch target {
            case let .post(post):
                await appState.reportClubNewsPost(for: club, post: post, reason: reason, details: details)
                localInfoMessage = "Post reported."
            case let .comment(comment):
                await appState.reportClubNewsComment(for: club, comment: comment, reason: reason, details: details)
                localInfoMessage = "Comment reported."
            }
            reportTarget = nil
        }
    }
}

extension ClubNewsView {
    @MainActor
    private func refreshVisibleChat() async {
        await appState.refreshClubNews(for: club)
        if isClubModerator {
            await appState.refreshClubNewsModerationReports(for: club)
        }
    }

    private func refreshMentionCandidates(for text: String) {
        guard let (query, _) = activeMentionQuery(in: text) else {
            mentionCandidates = []
            return
        }
        if appState.clubDirectoryMembers(for: club).isEmpty && !appState.isLoadingClubDirectory(for: club) {
            Task { await appState.refreshClubDirectoryMembers(for: club) }
        }
        let currentUserID = appState.authUserID
        let allMembers = appState.clubDirectoryMembers(for: club).filter { $0.id != currentUserID }
        mentionCandidates = filterMentionCandidates(allMembers, query: query)
    }
}

// MARK: - Chat Helpers

private func chatInitials(_ name: String) -> String {
    let parts = name.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    let chars = parts.prefix(2).compactMap(\.first)
    return chars.isEmpty ? "?" : String(chars).uppercased()
}

// MARK: - Mention Helpers

/// Returns the active mention query and the index of the `@` character if the text
/// ends with an open `@mention` (i.e. `@` at start or after whitespace, followed only
/// by name-valid characters — letters, spaces, hyphens, apostrophes).
private func activeMentionQuery(in text: String) -> (query: String, atIndex: String.Index)? {
    guard !text.isEmpty else { return nil }
    var i = text.endIndex
    while i > text.startIndex {
        i = text.index(before: i)
        guard text[i] == "@" else { continue }
        let precededByStartOrSpace = i == text.startIndex || text[text.index(before: i)].isWhitespace
        guard precededByStartOrSpace else { return nil }
        let afterAt = text.index(after: i)
        let query = String(text[afterAt...])
        let validScalars = CharacterSet.letters
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-'\u{2019}"))
        guard query.unicodeScalars.allSatisfy({ validScalars.contains($0) }) else { return nil }
        return (query, i)
    }
    return nil
}

/// Filters members whose name starts with `query` (case-insensitive) or whose last
/// name starts with `query`. Returns at most 5 results; returns the first 5 when
/// `query` is empty (just typed `@`).
private func filterMentionCandidates(_ members: [ClubDirectoryMember], query: String) -> [ClubDirectoryMember] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    if q.isEmpty { return Array(members.prefix(5)) }
    return members
        .filter { m in
            let name = m.name.lowercased()
            return name.hasPrefix(q) || name.contains(" \(q)")
        }
        .prefix(5)
        .map { $0 }
}

/// Inline autocomplete list shown inside composer cards when `@mention` is active.
@ViewBuilder
private func mentionCandidateList(
    _ candidates: [ClubDirectoryMember],
    onSelect: @escaping (ClubDirectoryMember) -> Void
) -> some View {
    VStack(spacing: 0) {
        ForEach(candidates) { member in
            Button { onSelect(member) } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(AvatarGradients.resolveGradient(forKey: member.avatarColorKey))
                        .overlay(
                            Text(chatInitials(member.name))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        )
                        .frame(width: 30, height: 30)
                    Text(member.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "at")
                        .font(.caption)
                        .foregroundStyle(Brand.pineTeal)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if member.id != candidates.last?.id {
                Divider().padding(.leading, 54)
            }
        }
    }
    .background(Color(.systemBackground))
}

// MARK: - Post Card

private struct ClubNewsPostCard: View {
    @EnvironmentObject private var appState: AppState
    let club: Club
    let post: ClubNewsPost
    let isClubModerator: Bool
    // Draft is owned by the card — typing here no longer re-renders sibling cards
    @State private var commentDraft: String = ""
    @State private var commentMentionCandidates: [ClubDirectoryMember] = []
    let onLike: () -> Void
    let onComment: (_ text: String, _ parentCommentID: UUID?) -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onHidePost: () -> Void
    let onReportPost: () -> Void
    let onDeleteComment: (ClubNewsComment) -> Void
    let onReportComment: (ClubNewsComment) -> Void
    @State private var replyTarget: ClubNewsComment?
    @State private var showingPostActions = false

    private var canDeletePost: Bool {
        guard let currentUserID = appState.authUserID else { return false }
        return isClubModerator || post.userID == currentUserID
    }

    private var canEditPost: Bool {
        guard let currentUserID = appState.authUserID else { return false }
        return post.userID == currentUserID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Announcement label
            if post.isAnnouncement {
                HStack(spacing: 5) {
                    Text("📣")
                        .font(.caption)
                    Text("Announcement")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                }
            }

            // Author row
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(AvatarGradients.resolveGradient(forKey: post.avatarColorKey))
                    .overlay(
                        Text(initials(post.authorName))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: 40, height: 40)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(post.authorName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(post.createdAt?.relativeDisplay() ?? "Just now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingPostActions = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Post options")
                }
            }

            // Post body
            if post.content.hasPrefix(sessionResultSentinel) {
                let jsonStr = String(post.content.dropFirst(sessionResultSentinel.count))
                if let data = jsonStr.data(using: .utf8),
                   let payload = try? JSONDecoder().decode(SessionResultPayload.self, from: data) {
                    SessionResultChatCardView(payload: payload)
                }
            } else if !post.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(post.content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Images
            if !post.imageURLs.isEmpty {
                ClubNewsImageGrid(urls: post.imageURLs)
            }

            // Action row
            HStack(spacing: 20) {
                Button(action: onLike) {
                    HStack(spacing: 4) {
                        Image(systemName: post.isLikedByCurrentUser ? "heart.fill" : "heart")
                        if post.likeCount > 0 {
                            Text("\(post.likeCount)")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(post.isLikedByCurrentUser ? Brand.spicyOrange : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(appState.isUpdatingClubNewsPost(post.id))
                .accessibilityLabel(post.isLikedByCurrentUser ? "Unlike post" : "Like post")

                HStack(spacing: 4) {
                    Image(systemName: "bubble.right")
                    if post.comments.count > 0 {
                        Text("\(post.comments.count)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.secondary)

                if appState.isUpdatingClubNewsPost(post.id) {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            // Comments thread
            if !post.comments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(threadedComments.topLevel) { comment in
                        commentRow(comment, isReply: false)
                        if let replies = threadedComments.repliesByParent[comment.id], !replies.isEmpty {
                            ForEach(replies) { reply in
                                commentRow(reply, isReply: true)
                            }
                        }
                    }
                }
            }

            // Reply target indicator
            if let replyTarget {
                HStack(spacing: 8) {
                    Label("Replying to \(replyTarget.authorName)", systemImage: "arrowshape.turn.up.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                    Spacer()
                    Button("Clear") { self.replyTarget = nil }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.secondary)
                }
            }

            // Mention autocomplete for reply composer
            if !commentMentionCandidates.isEmpty {
                mentionCandidateList(commentMentionCandidates) { member in
                    guard let (_, atIdx) = activeMentionQuery(in: commentDraft) else { return }
                    commentDraft = String(commentDraft[..<atIdx]) + "@\(member.name) "
                    commentMentionCandidates = []
                }
            }

            // Reply composer
            HStack(spacing: 8) {
                TextField("Write a reply… use @ to mention", text: $commentDraft)
                    .textInputAutocapitalization(.sentences)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onChange(of: commentDraft) { _, newText in
                        refreshCommentMentionCandidates(for: newText)
                    }

                Button {
                    let text = commentDraft
                    let parentID = replyTarget?.id
                    commentDraft = ""  // clear immediately; no need to wait for async
                    replyTarget = nil
                    onComment(text, parentID)
                } label: {
                    if appState.isCreatingClubNewsComment(for: post.id) {
                        ProgressView().tint(.white).controlSize(.small)
                            .frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 36)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Brand.pineTeal, in: Circle())
                .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isCreatingClubNewsComment(for: post.id))
                .opacity((commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isCreatingClubNewsComment(for: post.id)) ? 0.6 : 1)
                .accessibilityLabel("Send reply")
            }
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            if post.isAnnouncement {
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
                .fill(Brand.pineTeal)
                .frame(width: 4)
            }
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .confirmationDialog(
            "Post Options",
            isPresented: $showingPostActions,
            titleVisibility: .visible
        ) {
            Button("Hide Post") { onHidePost() }
            Button("Report Post") { onReportPost() }
            if canEditPost {
                Button("Edit Post") { onEdit() }
            }
            if canDeletePost {
                Button("Delete Post", role: .destructive) { onDelete() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let chars = parts.prefix(2).compactMap(\.first)
        return chars.isEmpty ? "M" : String(chars)
    }

    private func refreshCommentMentionCandidates(for text: String) {
        guard let (query, _) = activeMentionQuery(in: text) else {
            commentMentionCandidates = []
            return
        }
        if appState.clubDirectoryMembers(for: club).isEmpty && !appState.isLoadingClubDirectory(for: club) {
            Task { await appState.refreshClubDirectoryMembers(for: club) }
        }
        let currentUserID = appState.authUserID
        let allMembers = appState.clubDirectoryMembers(for: club).filter { $0.id != currentUserID }
        commentMentionCandidates = filterMentionCandidates(allMembers, query: query)
    }

    private var threadedComments: (topLevel: [ClubNewsComment], repliesByParent: [UUID: [ClubNewsComment]]) {
        let all = post.comments.sorted { lhs, rhs in
            (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
        }
        let replies = Dictionary(grouping: all.filter { $0.parentID != nil }) { $0.parentID! }
        let allIDs = Set(all.map(\.id))
        let top = all.filter { comment in
            guard let parentID = comment.parentID else { return true }
            return !allIDs.contains(parentID)
        }
        if top.isEmpty {
            return (all, [:])
        }
        return (top, replies)
    }

    private func canDeleteComment(_ comment: ClubNewsComment) -> Bool {
        guard let currentUserID = appState.authUserID else { return false }
        return isClubModerator || comment.userID == currentUserID
    }

    private func commentRow(_ comment: ClubNewsComment, isReply: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(AvatarGradients.resolveGradient(forKey: comment.avatarColorKey))
                .overlay(
                    Text(initials(comment.authorName))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                )
                .frame(width: isReply ? 28 : 32, height: isReply ? 28 : 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let created = comment.createdAt {
                        Text(created.relativeDisplay())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Reply") { replyTarget = comment }
                        Button("Report Comment") { onReportComment(comment) }
                        if canDeleteComment(comment) {
                            Button("Delete Comment", role: .destructive) {
                                onDeleteComment(comment)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Comment options")
                }
                Text(comment.content)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, isReply ? 20 : 0)
        .padding(.bottom, 6)
    }
}

private struct ClubNewsImageGrid: View {
    let urls: [URL]
    @State private var selectedIndex: Int?

    private var columns: [GridItem] {
        urls.count == 1 ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(urls.enumerated()), id: \.element.absoluteString) { index, url in
                Button {
                    selectedIndex = index
                } label: {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure:
                            ZStack {
                                Brand.secondarySurface
                                Image(systemName: "photo")
                                    .foregroundStyle(Brand.mutedText)
                            }
                            .frame(height: urls.count == 1 ? 180 : 120)
                        case .empty:
                            ZStack {
                                Brand.secondarySurface
                                ProgressView()
                            }
                            .frame(height: urls.count == 1 ? 180 : 120)
                        @unknown default:
                            Brand.secondarySurface
                                .frame(height: urls.count == 1 ? 180 : 120)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: urls.count == 1 ? 500 : 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .fullScreenCover(item: Binding<ClubNewsImageViewerTarget?>(
            get: { selectedIndex.map { ClubNewsImageViewerTarget(index: $0) } },
            set: { selectedIndex = $0?.index }
        )) { target in
            ClubNewsImageFullscreenViewer(urls: urls, startIndex: target.index)
        }
    }
}

private struct ClubNewsImageViewerTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct ClubNewsCommentDeletionTarget: Identifiable {
    let post: ClubNewsPost
    let comment: ClubNewsComment
    var id: UUID { comment.id }
}

private enum ClubNewsReportTarget: Identifiable {
    case post(ClubNewsPost)
    case comment(ClubNewsComment)

    var id: String {
        switch self {
        case let .post(post):
            return "post-\(post.id.uuidString)"
        case let .comment(comment):
            return "comment-\(comment.id.uuidString)"
        }
    }
}

private struct ClubNewsEditPostSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let post: ClubNewsPost
    let onSave: (_ content: String, _ retainedURLs: [URL], _ newUploads: [FeedImageUploadPayload]) async -> Void

    @State private var text: String
    @State private var retainedURLs: [URL]
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var newDraftImages: [DraftNewsImage] = []
    @State private var showAttachmentOptions = false
    @State private var showCamera = false

    init(post: ClubNewsPost, onSave: @escaping (_ content: String, _ retainedURLs: [URL], _ newUploads: [FeedImageUploadPayload]) async -> Void) {
        self.post = post
        self.onSave = onSave
        _text = State(initialValue: post.content)
        _retainedURLs = State(initialValue: post.imageURLs)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Post") {
                    TextField("Update post...", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .textInputAutocapitalization(.sentences)
                }

                if !retainedURLs.isEmpty {
                    Section("Photos") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(retainedURLs.enumerated()), id: \.element.absoluteString) { index, url in
                                    ZStack(alignment: .topTrailing) {
                                        AsyncImage(url: url) { phase in
                                            switch phase {
                                            case let .success(image):
                                                image.resizable().scaledToFill()
                                            default:
                                                ZStack {
                                                    Brand.secondarySurface
                                                    Image(systemName: "photo")
                                                }
                                            }
                                        }
                                        .frame(width: 84, height: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                        Button {
                                            retainedURLs.remove(at: index)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(.white, Brand.coralBlaze)
                                        }
                                        .offset(x: 6, y: -6)
                                    }
                                    .padding(.top, 6)
                                    .padding(.trailing, 4)
                                }
                            }
                        }
                    }
                }

                if !newDraftImages.isEmpty {
                    Section("New Photos") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(newDraftImages) { draft in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: draft.image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 84, height: 84)
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        Button {
                                            newDraftImages.removeAll { $0.id == draft.id }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(.white, Brand.coralBlaze)
                                        }
                                        .offset(x: 6, y: -6)
                                    }
                                    .padding(.top, 6)
                                    .padding(.trailing, 4)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showAttachmentOptions = true
                    } label: {
                        Label("Add Photos", systemImage: "photo.badge.plus")
                    }
                    .disabled(retainedURLs.count + newDraftImages.count >= 4 || appState.isUpdatingClubNewsPost(post.id))
                }
            }
            .navigationTitle("Edit Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            let uploads = newDraftImages.compactMap(\.uploadPayload)
                            await onSave(text, retainedURLs, uploads)
                        }
                    } label: {
                        if appState.isUpdatingClubNewsPost(post.id) {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        appState.isUpdatingClubNewsPost(post.id) ||
                        (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && retainedURLs.isEmpty && newDraftImages.isEmpty)
                    )
                }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: max(0, 4 - retainedURLs.count - newDraftImages.count),
                matching: .images
            )
            .onChange(of: selectedPhotoItems.count) { _, _ in
                Task { await loadPickedPhotos() }
            }
            .sheet(isPresented: $showCamera) {
                CameraCaptureView { image in
                    guard let image, retainedURLs.count + newDraftImages.count < 4 else { return }
                    newDraftImages.append(DraftNewsImage(image: image))
                }
            }
            .confirmationDialog("Add Photo", isPresented: $showAttachmentOptions, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") { showCamera = true }
                }
                Button("Choose from Photos") {
                    selectedPhotoItems = []
                    showPhotoPicker = true
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @MainActor
    private func loadPickedPhotos() async {
        guard !selectedPhotoItems.isEmpty else { return }
        for item in selectedPhotoItems {
            if retainedURLs.count + newDraftImages.count >= 4 { break }
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                newDraftImages.append(DraftNewsImage(image: image))
            }
        }
        selectedPhotoItems = []
    }
}

private struct ClubNewsModerationQueueSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let club: Club

    var body: some View {
        NavigationStack {
            List {
                if let error = appState.clubNewsReportsError(for: club), !error.isEmpty {
                    Section {
                        Text(error)
                            .foregroundStyle(Brand.spicyOrange)
                    }
                }

                if appState.isLoadingClubNewsReports(for: club) && appState.clubNewsReports(for: club).isEmpty {
                    Section {
                        ProgressView("Loading reports...")
                    }
                }

                if appState.clubNewsReports(for: club).isEmpty, !appState.isLoadingClubNewsReports(for: club) {
                    Section {
                        Text("No reports")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Reports") {
                        ForEach(appState.clubNewsReports(for: club)) { report in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(report.reason.capitalized)
                                            .font(.subheadline.weight(.semibold))
                                        Text(report.targetKind == .post ? "Post report" : "Comment report")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let createdAt = report.createdAt {
                                        Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text("From \(report.senderName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !report.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(report.details)
                                        .font(.caption)
                                        .foregroundStyle(Brand.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Button {
                                    Task { await appState.resolveClubNewsModerationReport(for: club, report: report) }
                                } label: {
                                    HStack(spacing: 8) {
                                        if appState.isResolvingClubNewsReport(report.id) {
                                            ProgressView()
                                        } else {
                                            Image(systemName: "checkmark.circle")
                                        }
                                        Text("Resolve")
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(appState.isResolvingClubNewsReport(report.id))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Moderation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await appState.refreshClubNewsModerationReports(for: club) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
            .task {
                if appState.clubNewsReports(for: club).isEmpty {
                    await appState.refreshClubNewsModerationReports(for: club)
                }
            }
        }
    }
}

private struct ClubNewsImageFullscreenViewer: View {
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]
    let startIndex: Int
    @State private var selection: Int

    init(urls: [URL], startIndex: Int) {
        self.urls = urls
        self.startIndex = startIndex
        _selection = State(initialValue: startIndex)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                TabView(selection: $selection) {
                    ForEach(Array(urls.enumerated()), id: \.element.absoluteString) { index, url in
                        ZoomableAsyncImage(url: url)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .principal) {
                    Text("\(selection + 1) of \(urls.count)")
                        .foregroundStyle(.white)
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private struct ZoomableAsyncImage: View {
    let url: URL
    @State private var scale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(max(value, 1), 4)
                                }
                                .onEnded { _ in
                                    if scale < 1.05 { scale = 1 }
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                scale = scale > 1.2 ? 1 : 2
                            }
                        }
                case .empty:
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                @unknown default:
                    EmptyView()
                }
            }
        }
    }
}

private struct DraftNewsImage: Identifiable {
    let id = UUID()
    let image: UIImage

    var uploadPayload: FeedImageUploadPayload? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        return FeedImageUploadPayload(data: data, contentType: "image/jpeg", fileExtension: "jpg")
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage?) -> Void
        let dismiss: DismissAction

        init(onCapture: @escaping (UIImage?) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
            dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let image = info[.originalImage] as? UIImage
            onCapture(image)
            dismiss()
        }
    }
}

// MARK: - Session Result Chat Card

private struct SessionResultChatCardView: View {
    let payload: SessionResultPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
                .padding(.vertical, 12)
            roundsSection
            if let champ = payload.champion, let label = payload.championLabel {
                Divider()
                    .padding(.vertical, 12)
                championSection(name: champ, label: label)
            }
        }
        .padding(14)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("🏓")
                    .font(.caption)
                Text("Session Results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(payload.gameTitle)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(payload.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Rounds

    private var roundsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(payload.rounds, id: \.number) { round in
                roundView(round)
            }
        }
    }

    @ViewBuilder
    private func roundView(_ round: SessionResultPayload.SRRound) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Round \(round.number)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(round.courts, id: \.courtNumber) { court in
                    courtView(court)
                }
            }
        }
    }

    @ViewBuilder
    private func courtView(_ court: SessionResultPayload.SRCourt) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if court.showLabel {
                Text("COURT \(court.courtNumber)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.8)
                    .padding(.bottom, 1)
            }
            if let match = court.result {
                matchRow(names: match.topNames, score: match.topScore, isWinner: match.topIsWinner)
                matchRow(names: match.bottomNames, score: match.bottomScore, isWinner: match.bottomIsWinner)
            } else {
                Text("No result recorded")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func matchRow(names: String, score: Int, isWinner: Bool) -> some View {
        HStack(spacing: 0) {
            Text(names)
                .font(.subheadline.weight(isWinner ? .semibold : .regular))
                .foregroundStyle(isWinner ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                Text("\(score)")
                    .font(.subheadline.weight(isWinner ? .bold : .regular))
                    .foregroundStyle(isWinner ? Color.primary : Color.secondary)
                    .monospacedDigit()
                    .frame(width: 26, alignment: .trailing)

                if isWinner {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.emeraldAction)
                        .frame(width: 22)
                } else {
                    Spacer()
                        .frame(width: 22)
                }
            }
        }
    }

    // MARK: Champion

    @ViewBuilder
    private func championSection(name: String, label: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("🏆")
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
