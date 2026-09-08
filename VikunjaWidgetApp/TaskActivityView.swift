import SwiftUI

struct TaskActivityView: View {
    let task: VikunjaTask
    @Environment(TaskStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    @State private var comments: [VikunjaComment] = []
    @State private var page = 1
    @State private var hasEarlierPage = false
    @State private var isLoading = false
    @State private var loadError: String?
    /// False for a terminal cause, so no Retry button is offered.
    @State private var canRetryLoad = true
    @State private var isExpanded = false
    @State private var composer = ""
    /// Identifies a comment the user can act on.
    ///
    /// `commentId` is nil while the comment is still queued and has no server
    /// id yet — carrying the `clientCommentId` alongside is what lets
    /// `CommentOutbox` amend that queued create instead of appending a second
    /// operation.
    ///
    /// `clientCommentId` is nil for a server comment with no queued operation —
    /// there is no client id to reuse, and one is minted at action time.
    ///
    /// It must NOT be minted here. `editableTarget(for:)` runs inside `body`,
    /// once or twice per render, so a `?? UUID()` made two targets for the same
    /// comment unequal and silently killed `if editingTarget == pendingDelete`.
    /// Identity has to survive a re-render.
    private struct CommentTarget: Equatable {
        let commentId: Int?
        let clientCommentId: UUID?
    }

    @State private var editingTarget: CommentTarget?
    @State private var pendingDelete: CommentTarget?
    /// Comments the reader has opened past the 4-line clamp. Real comments on
    /// this instance run 125-616 characters (median ~370, about 7 lines at the
    /// editor's 452 pt), so the clamp is the common case, not the exception.
    @State private var unclamped: Set<TaskActivityItem.Identity> = []
    #if os(iOS)
    /// The one row whose swipe actions are open. Only one at a time, like Mail.
    @State private var swipedItem: TaskActivityItem.Identity?
    #endif

    private var insetBg: Color { colorScheme == .dark ? Color(red: 42/255, green: 42/255, blue: 45/255) : Color(red: 245/255, green: 245/255, blue: 247/255) }
    private var primary: Color { colorScheme == .dark ? Color(red: 242/255, green: 242/255, blue: 247/255) : Color(red: 28/255, green: 28/255, blue: 30/255) }
    private var muted: Color { colorScheme == .dark ? Color(red: 134/255, green: 134/255, blue: 140/255) : Color(red: 138/255, green: 138/255, blue: 142/255) }
    private var hairline: Color { colorScheme == .dark ? .white.opacity(0.10) : Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.10) }
    private var accent: Color { colorScheme == .dark ? Color(red: 10/255, green: 132/255, blue: 255/255) : Color(red: 0, green: 122/255, blue: 255/255) }
    private var railDot: Color { colorScheme == .dark ? Color(red: 85/255, green: 85/255, blue: 92/255) : Color(red: 190/255, green: 190/255, blue: 196/255) }

    private var taskRef: TaskRef? {
        guard task.id > 0 else { return store.outbox.clientId(forPlaceholder: task.id).map(TaskRef.client) }
        return .server(task.id)
    }

    /// Changes when anything about THIS task's queued comments changes: which
    /// ops exist, their text, or their state. The reload trigger keys off this
    /// rather than the global `operations.count`, which both over-fired (a
    /// comment on another task reset this view to page 1) and under-fired (an
    /// in-place edit, or pending -> failed, leaves the count identical).
    private var overlayFingerprint: [String] {
        guard let taskRef else { return [] }
        return store.commentOutbox.overlays(for: taskRef).map { overlay in
            "\(overlay.id)|\(overlay.serverId.map(String.init) ?? "-")|\(overlay.text)|\(overlay.state)"
        }
    }

    private var items: [TaskActivityItem] {
        let overlays = taskRef.map { store.commentOutbox.overlays(for: $0) } ?? []
        return TaskActivityProjection.project(task: task, comments: comments, overlays: overlays)
    }

    var body: some View {
        // Comments are a v2-only endpoint. On an older server every send would
        // queue an operation that can never be delivered, so offer nothing to
        // send rather than accepting text and failing later. Local-only
        // activity (created / completed) still has value, so the section stays.
        let canComment = store.supportsComments

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(primary)
                Spacer()
                if items.count > 1 {
                    Button(isExpanded ? "Hide activity" : "Show \(items.count) activity items") {
                        isExpanded.toggle()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .buttonStyle(.plain)
                }
            }

            if isLoading && items.isEmpty {
                Text("Loading activity…").font(.system(size: 13)).foregroundStyle(muted)
            } else if items.isEmpty {
                Text("No activity yet. Comments and completed subtasks appear here.")
                    .font(.system(size: 13)).foregroundStyle(muted)
            } else {
                timeline(isExpanded ? items : Array(items.prefix(1)))
                if isExpanded, hasEarlierPage {
                    Button("Load earlier activity") { Task { await load(page: page + 1, append: true) } }
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(accent).buttonStyle(.plain)
                }
            }

            // Both, and this one first. These were an if/else, so a load
            // failure hid the "an update needs attention" banner entirely —
            // and offline is exactly when BOTH happen, which made the banner
            // unreachable in its most important case. The user's own unsent
            // text outranks a stale read.
            if let ref = taskRef, store.commentOutbox.hasFailure(for: ref) {
                statusBanner("An update needs attention", action: "Review updates") { store.pendingChangesRequested = true }
            }

            if let loadError {
                if canRetryLoad {
                    statusBanner(loadError, action: "Retry") { Task { await load(page: 1, append: false) } }
                } else {
                    Text(loadError).font(.system(size: 13)).foregroundStyle(muted)
                }
            }

            if canComment {
                composerRow
            }
        }
        .padding(14)
        .background(insetBg)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .task(id: task.id) {
            guard task.id > 0 else { return }
            store.refreshServerCapabilities()
            await load(page: 1, append: false)
            // Cached on the store, per account. Held per-view with `try?` this
            // was one dropped request away from silently making every comment
            // look like someone else's.
            await store.loadCurrentUserIfNeeded()
        }
        // Scoped to THIS task, and to a value that changes on state
        // transitions. Watching the global `operations.count` meant a comment
        // queued on any other task reset this view to page 1, throwing away
        // everything "Load earlier activity" had pulled in — while an in-place
        // edit or a pending -> failed transition, which leave the count alone,
        // fired nothing at all.
        .onChange(of: overlayFingerprint) {
            Task { await load(page: 1, append: false) }
        }
        .confirmationDialog(
            "Delete this update?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete update", role: .destructive) {
                if let pendingDelete {
                    if editingTarget == pendingDelete { cancelEditing() }
                    store.queueCommentDelete(
                        task: task,
                        commentId: pendingDelete.commentId,
                        // Minted here, at action time — never in `body`.
                        clientCommentId: pendingDelete.clientCommentId ?? UUID()
                    )
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes it for everyone on the task.")
        }
    }

    // MARK: - Timeline

    /// A single hairline rail with a dot per event. Automatic events sit on one
    /// 13 pt line so they stay visibly subordinate to comments even when a
    /// subtask title wraps; comments get the 15 pt body and room to breathe.
    private func timeline(_ shown: [TaskActivityItem]) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(hairline)
                .frame(width: 1)
                .padding(.leading, 4)
                .padding(.top, 8)
                .padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { row($0) }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TaskActivityItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            dot(isComment: item.isComment)
            if item.isComment {
                commentBody(item)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.text)
                        .font(.system(size: 13))
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(timeText(item.timestamp))
                        .font(.system(size: 12))
                        .foregroundStyle(muted)
                }
                .padding(.bottom, 14)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func dot(isComment: Bool) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(isComment ? accent : railDot)
                .frame(width: isComment ? 9 : 7, height: isComment ? 9 : 7)
                .background(Circle().fill(insetBg).frame(width: 15, height: 15))
            Spacer(minLength: 0)
        }
        .frame(width: 9)
        .padding(.top, isComment ? 6 : 5)
    }

    @ViewBuilder
    private func commentBody(_ item: TaskActivityItem) -> some View {
        let card = commentCard(item)
        #if os(iOS)
        if let target = editableTarget(for: item) {
            swipeRow(card, item: item, target: target)
        } else {
            card
        }
        #else
        card
        #endif
    }

    @ViewBuilder
    private func commentCard(_ item: TaskActivityItem) -> some View {
        let isClamped = !unclamped.contains(item.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let author = item.author {
                    Text(author.username ?? author.name ?? "Update")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primary)
                }
                Text(timeText(item.timestamp)).font(.system(size: 12)).foregroundStyle(muted)
                if item.commentId == nil { stateChip(for: item.localOverlay?.state) }
                Spacer(minLength: 0)
                if let target = editableTarget(for: item) {
                    commentMenu(item, target: target)
                }
            }
            Text(rendered(item.text))
                .font(.system(size: 15))
                .foregroundStyle(item.commentId == nil ? muted : primary)
                .lineLimit(isClamped ? 4 : nil)
                .fixedSize(horizontal: false, vertical: true)
            // Per-comment, independent of the section's own expansion: a single
            // 616-character comment is otherwise taller than every other event
            // in the task put together, and pushes the composer off screen.
            if isClamped, item.text.count > 180 {
                Button("Show more") { unclamped.insert(item.id) }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .buttonStyle(.plain)
            } else if !isClamped {
                Button("Show less") { unclamped.remove(item.id) }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 18)
    }

    /// A comment that has no server id yet is either on its way or stuck. The
    /// chip used to say "Sending" for both, so a permanently failed comment sat
    /// there claiming to be in flight forever — and the only other signal, the
    /// failure banner, was itself being shadowed by a load error.
    @ViewBuilder
    private func stateChip(for state: LocalCommentOverlay.State?) -> some View {
        switch state {
        case .retryableFailed, .permanentlyFailed:
            chip("Not sent", tint: .red)
        case .deleting:
            chip("Removing", tint: muted)
        default:
            chip("Sending", tint: muted)
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(text).font(.system(size: 11)).foregroundStyle(tint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(hairline))
    }

    /// What the user may act on, and with which identity.
    ///
    /// A comment still in the queue is ours by construction — it has no author
    /// from the server yet, so the `author.id == currentUser.id` test that
    /// gates server comments would wrongly hide it.
    private func editableTarget(for item: TaskActivityItem) -> CommentTarget? {
        // No editing at all on a server that cannot accept comments. Gating
        // only the composer left Edit reachable from the menu and the swipe
        // row, which put the user into an edit mode with no field, no Save and
        // no Cancel — invisible and inescapable.
        guard store.supportsComments else { return nil }

        if item.commentId == nil {
            guard let overlay = item.localOverlay, overlay.state != .deleting else { return nil }
            return CommentTarget(commentId: nil, clientCommentId: overlay.id)
        }
        guard let commentId = item.commentId, store.currentUser?.id == item.author?.id else { return nil }
        // Reuse the queued op's client id when one exists, so an edit displaces
        // that op rather than racing it. Nil otherwise — see CommentTarget.
        return CommentTarget(commentId: commentId, clientCommentId: item.localOverlay?.id)
    }

    @ViewBuilder
    private func commentMenu(_ item: TaskActivityItem, target: CommentTarget) -> some View {
        Menu {
            Button("Edit update") {
                composer = item.text
                editingTarget = target
            }
            Divider()
            // macOS does not tint a destructive menu item, so "Delete update"
            // reads exactly like "Edit update" there. The confirmation, not the
            // colour, is what stops a mis-click deleting a comment.
            Button("Delete update…", role: .destructive) { pendingDelete = target }
        } label: {
            // The full 44 pt minimum target. Negative padding to buy the
            // height back does not work: it clips the hit region and the
            // accessibility frame with it, giving a 44x28 target that only
            // looks compliant.
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(muted)
        .accessibilityLabel("More actions for your update")
    }

    #if os(iOS)
    private static let swipeOpenWidth: CGFloat = 152

    /// `.swipeActions` only works on a `List` row, and the timeline is a
    /// `ZStack`/`VStack`, so the modifier was silently dead. This is the same
    /// accelerator built by hand.
    ///
    /// The offset is set in `onEnded`, not `onChanged`: tracking the finger
    /// continuously means competing with the editor's vertical `ScrollView`
    /// for every event. Snapping at the end of the gesture costs the rubber
    /// band and keeps scrolling reliable.
    @ViewBuilder
    private func swipeRow<Content: View>(
        _ content: Content,
        item: TaskActivityItem,
        target: CommentTarget
    ) -> some View {
        let isOpen = swipedItem == item.id
        ZStack(alignment: .trailing) {
            // Rendered only while open. `opacity(0)` leaves the buttons in the
            // accessibility tree, so VoiceOver announced "Edit"/"Delete" on
            // every comment and automation could tap a hidden control.
            if isOpen {
                HStack(spacing: 0) {
                    swipeButton("Edit", fill: accent) {
                        closeSwipe()
                        composer = item.text
                        editingTarget = target
                    }
                    swipeButton("Delete", fill: .red) {
                        closeSwipe()
                        pendingDelete = target
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 18)
                .transition(.opacity)
            }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(insetBg)
                .offset(x: isOpen ? -Self.swipeOpenWidth : 0)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    // Vertical-dominant drags belong to the ScrollView.
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    withAnimation(.snappy(duration: 0.22)) {
                        swipedItem = value.translation.width < 0 ? item.id : nil
                    }
                }
        )
    }

    private func swipeButton(_ title: String, fill: Color, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 76, height: 44)
                .background(fill)
        }
        .buttonStyle(.plain)
    }

    private func closeSwipe() {
        withAnimation(.snappy(duration: 0.18)) { swipedItem = nil }
    }
    #endif

    // MARK: - Chrome

    private func statusBanner(_ text: String, action: String, run: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(.system(size: 12)).foregroundStyle(muted)
            Spacer()
            Button(action, action: run).font(.system(size: 12, weight: .medium)).buttonStyle(.plain).foregroundStyle(accent)
        }
        .padding(10)
        .background(accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var canSend: Bool {
        !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func cancelEditing() {
        editingTarget = nil
        composer = ""
    }

    @ViewBuilder
    private var composerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Without this row nothing says the next send REPLACES an existing
            // update rather than posting a new one, and there is no way back
            // out of edit mode short of clearing the field by hand.
            if editingTarget != nil {
                HStack(spacing: 8) {
                    // Decorative: SF Symbols auto-labels this "Edit", so
                    // VoiceOver read it out beside the banner text that
                    // already says the same thing.
                    Image(systemName: "pencil").font(.system(size: 11))
                        .accessibilityHidden(true)
                    Text("Editing your update").font(.system(size: 12))
                    Spacer(minLength: 0)
                    Button("Cancel", action: cancelEditing)
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                }
                .foregroundStyle(muted)
            }
            HStack(spacing: 8) {
                TextField(editingTarget == nil ? "Add an update" : "Edit your update", text: $composer, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(editingTarget == nil ? "Add an update" : "Edit your update")
                Button {
                    let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    if let editingTarget {
                        store.queueCommentUpdate(
                            task: task,
                            commentId: editingTarget.commentId,
                            clientCommentId: editingTarget.clientCommentId ?? UUID(),
                            text: text
                        )
                        self.editingTarget = nil
                    } else {
                        store.queueComment(task: task, text: text)
                    }
                    composer = ""
                    isExpanded = true
                } label: {
                    // `.disabled` does not dim a plain button that sets its own
                    // foregroundStyle, so the tint has to carry the state.
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(canSend ? accent : muted.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(editingTarget == nil ? "Add update" : "Save update")
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(editingTarget == nil ? hairline : accent.opacity(0.5)))
    }

    // MARK: - Text

    /// Comment bodies on this server are plain text carrying inline markdown
    /// (`**04/09**`) and blank-line paragraph breaks — verified against live
    /// data, never HTML. `.inlineOnlyPreservingWhitespace` is the one option
    /// that renders the emphasis AND keeps the paragraph breaks; the default
    /// collapses them into one run-on line.
    private func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func load(page: Int, append: Bool) async {
        guard task.id > 0, let taskRef else { return }
        guard !store.commentOutbox.blocksRefresh(for: taskRef) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await VikunjaAPI.fetchCommentPage(taskId: task.id, page: page)
            if append {
                // `uniquingKeysWith`, matching VikunjaAPI.swift:107 — a duplicate
                // id traps. Overlapping pages are exactly what paging exposes us
                // to when someone else writes while the user is loading.
                var merged = Dictionary(
                    comments.map { ($0.id, $0) },
                    uniquingKeysWith: { _, latest in latest }
                )
                for comment in result.items { merged[comment.id] = comment }
                comments = Array(merged.values)
            } else {
                // The server can repeat an id within one page too; dedupe here
                // as well or the next append traps on the seeded duplicate.
                comments = Array(
                    Dictionary(
                        result.items.map { ($0.id, $0) },
                        uniquingKeysWith: { _, latest in latest }
                    ).values
                )
            }
            comments.sort { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }
            self.page = result.page
            hasEarlierPage = result.hasEarlierPage
            loadError = nil
        } catch is VikunjaAPI.V2NotAvailable {
            // Terminal, not a blip. Offering "Retry" for a capability the
            // client already knows is absent is a button that can never work.
            loadError = String(
                localized: "This server doesn’t support comments.",
                comment: "Shown when the Vikunja server has no v2 comment API"
            )
            canRetryLoad = false
        } catch {
            DiagnosticLog.warn("comment load failed")
            loadError = append
                ? String(localized: "Couldn’t load earlier activity", comment: "Activity paging error")
                : String(localized: "Couldn’t load newer activity", comment: "Activity refresh error")
            canRetryLoad = true
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private static let datedYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        return f
    }()

    /// A bare time reads as "today" to everyone. Comments on this instance are
    /// routinely days old, so anything outside today carries its day: without
    /// it a comment from 4 September and a task created this morning are
    /// indistinguishable in the rail.
    private func timeText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        let day = (sameYear ? Self.dayFormatter : Self.datedYearFormatter).string(from: date)
        return "\(day) \(time)"
    }
}
