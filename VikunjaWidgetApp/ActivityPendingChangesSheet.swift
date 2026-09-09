import SwiftUI

/// One row in the forked Pending Changes sheet.
///
/// A superset of upstream's `PendingChange`: it carries the queued comment's
/// text, why it stopped, and whether the user can ask for it again. Wrapping
/// rather than extending keeps upstream's type untouched — that struct is
/// memberwise-initialised in `TaskStore.pendingChanges`, so every field added
/// to it is a line of drift in the highest-churn file in the fork.
struct ActivityPendingRow: Identifiable {
    let id: UUID            // the queued op's id — the discard handle
    let icon: String        // SF Symbol
    let kindLabel: String   // "New task", "Edit", "Update", …
    let taskTitle: String
    let queuedAt: Date
    /// True for a queued `.create`: discarding deletes the task outright,
    /// because it exists nowhere but this queue. Drives the harsher confirm.
    let deletesTask: Bool
    /// A queued comment's text. This sheet is the only place a failed comment
    /// can be seen at all, and without it the user is asked to discard
    /// something they cannot read.
    var body: String? = nil
    /// Why it stopped, shown verbatim. Nil while the op is merely pending.
    var errorMessage: String? = nil
    /// True for an op the user can ask to send again. A comment that gave up —
    /// on the retry ceiling, or as an ambiguous create — is otherwise a dead
    /// row whose only action is discard.
    var canRetry: Bool = false
    /// Discarding a queued comment does not touch the task, so the task-shaped
    /// warning copy would misdescribe it.
    var isComment: Bool = false

    /// Lifts an upstream row unchanged. Every task-shaped field keeps its
    /// meaning; only the comment-only fields default away.
    init(_ change: PendingChange) {
        self.id = change.id
        self.icon = change.icon
        self.kindLabel = change.kindLabel
        self.taskTitle = change.taskTitle
        self.queuedAt = change.queuedAt
        self.deletesTask = change.deletesTask
    }

    init(
        id: UUID, icon: String, kindLabel: String, taskTitle: String, queuedAt: Date,
        deletesTask: Bool, body: String? = nil, errorMessage: String? = nil,
        canRetry: Bool = false, isComment: Bool = false
    ) {
        self.id = id
        self.icon = icon
        self.kindLabel = kindLabel
        self.taskTitle = taskTitle
        self.queuedAt = queuedAt
        self.deletesTask = deletesTask
        self.body = body
        self.errorMessage = errorMessage
        self.canRetry = canRetry
        self.isComment = isComment
    }
}

/// A fork of upstream's `PendingChangesSheet`, presented in its place.
///
/// A copy rather than an edit because the feature changed nine things in it —
/// the row layout, both confirmation dialogs, and all three footer buttons —
/// which is +55/-8 of permanent conflict surface in a file upstream still
/// touches. `PendingChangesSheet.swift` stays compiled and byte-identical to
/// upstream; when it changes, port the change here by hand:
///
///     git diff <previous-merge>..main -- VikunjaWidgetApp/PendingChangesSheet.swift
///
/// Compile errors catch API-shaped drift; visual drift is what that diff is for.
struct ActivityPendingChangesSheet: View {
    var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var changeToDiscard: ActivityPendingRow?
    @State private var showDiscardAll = false

    var body: some View {
        NavigationStack {
            Group {
                if store.activityPendingRows.isEmpty {
                    // The queue drained while the sheet was open. Don't
                    // auto-dismiss — yanking the sheet away mid-read is the
                    // disorientation this feature exists to fix.
                    ContentUnavailableView {
                        Label(String(localized: "All changes synced", table: "Activity"), systemImage: "checkmark.circle")
                    } description: {
                        Text(String(localized: "Everything on this device has reached your server.", table: "Activity"))
                    }
                } else {
                    changeList
                }
            }
            .navigationTitle(String(localized: "Pending Changes", table: "Activity"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", table: "Activity")) { dismiss() }
                }
            }
            .confirmationDialog(
                discardTitle,
                isPresented: Binding(
                    get: { changeToDiscard != nil },
                    set: { if !$0 { changeToDiscard = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let change = changeToDiscard {
                    if change.deletesTask {
                        Button(String(localized: "Delete Task", table: "Activity"), role: .destructive) {
                            Task { await store.discardAny(opId: change.id) }
                        }
                    } else {
                        Button(String(localized: "Discard Change", table: "Activity"), role: .destructive) {
                            Task { await store.discardAny(opId: change.id) }
                        }
                    }
                }
                Button(String(localized: "Cancel", table: "Activity"), role: .cancel) {}
            } message: {
                if let change = changeToDiscard {
                    if change.deletesTask {
                        Text(String(localized: "\"\(change.taskTitle)\" was never uploaded to your server, so discarding it deletes it permanently.", table: "Activity"))
                    } else if change.isComment {
                        // Nothing about the task changes when a queued comment
                        // is dropped; the task-shaped copy misdescribed it.
                        Text(String(localized: "Your update won't be posted, and the text will be lost.", table: "Activity"))
                    } else {
                        Text(String(localized: "The task will go back to the version on your server. Your change will be lost.", table: "Activity"))
                    }
                }
            }
            .confirmationDialog(
                String(localized: "Discard all pending changes?", table: "Activity"),
                isPresented: $showDiscardAll,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Discard All", table: "Activity"), role: .destructive) {
                    Task { await store.discardEverything() }
                }
                Button(String(localized: "Cancel", table: "Activity"), role: .cancel) {}
            } message: {
                discardAllMessage
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    private var discardTitle: String {
        guard let change = changeToDiscard else { return String(localized: "Discard this change?", table: "Activity") }
        if change.deletesTask { return String(localized: "Delete this task?", table: "Activity") }
        return change.isComment ? String(localized: "Discard this update?", table: "Activity") : String(localized: "Discard this change?", table: "Activity")
    }

    // MARK: - List

    private var changeList: some View {
        List {
            if let message = store.lastDrainFailureMessage {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                ForEach(store.activityPendingRows) { change in
                    row(for: change)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { footerButtons }
    }

    private func row(for change: ActivityPendingRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: change.icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.kindLabel)
                    .font(.headline)
                Text(change.taskTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let body = change.body {
                    Text(body)
                        .font(.subheadline)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
                if let errorMessage = change.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                Text(change.queuedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            // No swipeActions — macOS has none, and a context menu alone is
            // undiscoverable (AccountListView precedent). Visible button on both.
            VStack(alignment: .trailing, spacing: 6) {
                if change.canRetry {
                    Button(String(localized: "Retry", table: "Activity")) {
                        Task { await store.retryComment(opId: change.id) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isBusy)
                }
                Button(String(localized: "Discard", table: "Activity")) { changeToDiscard = change }
                    .buttonStyle(.borderless)
                    .disabled(store.isBusy)
            }
        }
        .padding(.vertical, 2)
    }

    private var footerButtons: some View {
        HStack {
            Button {
                // Both queues. Upstream drains only the task outbox, so the one
                // control offered for unsticking work never touched a comment.
                Task { await store.retryAll() }
            } label: {
                Label(String(localized: "Try Again", table: "Activity"), systemImage: "arrow.clockwise")
            }
            .disabled(store.isBusy)

            Spacer()

            Button(role: .destructive) {
                showDiscardAll = true
            } label: {
                Label(String(localized: "Discard All", table: "Activity"), systemImage: "trash")
            }
            .disabled(store.isBusy)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Copy

    /// These three MUST stay `Text(_:tableName:)` — i.e. a LocalizedStringKey,
    /// not `Text(String(localized:table:))`. Automatic grammar agreement
    /// (`^[…](inflect: true)`) is applied on the LocalizedStringKey path only;
    /// through `String(localized:)` the markup reaches the screen verbatim, as
    /// "This will undo ^[1 change](inflect: true)". Verified on the simulator
    /// 2026-09-09 — it renders, it does not crash, and no test would catch it.
    ///
    /// "This will delete 3 new tasks and undo 17 changes. This cannot be undone."
    /// — with a zero half dropped entirely.
    ///
    /// Built as three whole-sentence `Text` literals rather than by joining
    /// String fragments: a literal reaches the string catalog and can be
    /// translated, while an interpolated `String` cannot and would ship this
    /// dialog as permanent English. `^[…](inflect: true)` is what pluralizes
    /// "task"/"tasks" — hand-rolled `== 1 ? "" : "s"` only ever works for
    /// English, and most of Veyrn's users aren't in an English-speaking market.
    @ViewBuilder
    private var discardAllMessage: some View {
        let summary = store.activityDiscardSummary
        if summary.creates > 0 && summary.others > 0 {
            Text("This will delete ^[\(summary.creates) new task](inflect: true) and undo ^[\(summary.others) change](inflect: true). This cannot be undone.", tableName: "Activity")
        } else if summary.creates > 0 {
            Text("This will delete ^[\(summary.creates) new task](inflect: true). This cannot be undone.", tableName: "Activity")
        } else {
            Text("This will undo ^[\(summary.others) change](inflect: true). This cannot be undone.", tableName: "Activity")
        }
    }
}
