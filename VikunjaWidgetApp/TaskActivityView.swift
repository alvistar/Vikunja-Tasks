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
    @State private var isExpanded = false
    @State private var composer = ""
    @State private var currentUser: VikunjaCurrentUser?
    @State private var editingCommentId: Int?

    private var insetBg: Color { colorScheme == .dark ? Color(red: 42/255, green: 42/255, blue: 45/255) : Color(red: 245/255, green: 245/255, blue: 247/255) }
    private var muted: Color { colorScheme == .dark ? Color(red: 134/255, green: 134/255, blue: 140/255) : Color(red: 138/255, green: 138/255, blue: 142/255) }
    private var hairline: Color { colorScheme == .dark ? .white.opacity(0.10) : Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.10) }
    private var accent: Color { colorScheme == .dark ? Color(red: 10/255, green: 132/255, blue: 255/255) : Color(red: 0, green: 122/255, blue: 255/255) }

    private var taskRef: TaskRef? {
        guard task.id > 0 else { return store.outbox.clientId(forPlaceholder: task.id).map(TaskRef.client) }
        return .server(task.id)
    }

    private var items: [TaskActivityItem] {
        let overlays = taskRef.map { store.commentOutbox.overlays(for: $0) } ?? []
        return TaskActivityProjection.project(task: task, comments: comments, overlays: overlays)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(.system(size: 15, weight: .semibold))
                Spacer()
                if items.count > 1 {
                    Button(isExpanded ? "Hide activity" : "Show \(items.count) activity items") {
                        isExpanded.toggle()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Hide activity" : "Show \(items.count) activity items")
                }
            }

            if isLoading && items.isEmpty {
                Text("Loading activity…").font(.system(size: 13)).foregroundStyle(muted).padding(.top, 10)
            } else if let preview = items.first {
                activityRow(preview).padding(.top, 10)
                if isExpanded {
                    ForEach(items.dropFirst()) { activityRow($0).padding(.top, 8) }
                    if hasEarlierPage {
                        Button("Load earlier activity") { Task { await load(page: page + 1, append: true) } }
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(accent).buttonStyle(.plain).padding(.top, 10)
                    }
                }
            } else {
                Text("No activity yet. Comments and completed subtasks appear here.")
                    .font(.system(size: 13)).foregroundStyle(muted).padding(.top, 10)
            }

            if let loadError {
                HStack {
                    Text(loadError).font(.system(size: 12)).foregroundStyle(muted)
                    Spacer()
                    Button("Retry") { Task { await load(page: 1, append: false) } }.font(.system(size: 12, weight: .medium)).buttonStyle(.plain).foregroundStyle(accent)
                }
                .padding(10).background(accent.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.top, 10)
            } else if let ref = taskRef, store.commentOutbox.hasFailure(for: ref) {
                HStack {
                    Text("An update needs attention").font(.system(size: 12)).foregroundStyle(muted)
                    Spacer()
                    Button("Review updates") { store.pendingChangesRequested = true }.font(.system(size: 12, weight: .medium)).buttonStyle(.plain).foregroundStyle(accent)
                }
                .padding(10).background(accent.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.top, 10)
            }

            composerRow
        }
        .padding(14)
        .background(insetBg)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .task(id: task.id) {
            guard task.id > 0 else { return }
            await load(page: 1, append: false)
            currentUser = try? await VikunjaAPI.fetchCurrentUser()
        }
        .onChange(of: store.commentOutbox.operations.count) {
            Task { await load(page: 1, append: false) }
        }
    }

    private var composerRow: some View {
        HStack(spacing: 8) {
            TextField("Add an update", text: $composer, axis: .vertical)
                .font(.system(size: 13))
                .lineLimit(1...3)
                .accessibilityLabel("Add an update")
            Button {
                let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                if let editingCommentId {
                    store.queueCommentUpdate(task: task, commentId: editingCommentId, text: text)
                    self.editingCommentId = nil
                } else {
                    store.queueComment(task: task, text: text)
                }
                composer = ""
                isExpanded = true
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .disabled(composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Add update")
        }
        .padding(10).overlay(RoundedRectangle(cornerRadius: 12).stroke(hairline)).padding(.top, 12)
    }

    @ViewBuilder
    private func activityRow(_ item: TaskActivityItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.isComment ? "text.bubble" : "checkmark.circle")
                .foregroundStyle(accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.author.map { "\($0.username ?? $0.name ?? "Update") · \(item.text)" } ?? item.text)
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text(timeText(item.timestamp)).font(.system(size: 11)).foregroundStyle(muted)
            }
            Spacer(minLength: 0)
            if let commentId = item.commentId, currentUser?.id == item.author?.id {
                Menu {
                    Button("Edit update") {
                        composer = item.text
                        editingCommentId = commentId
                    }
                    Divider()
                    Button("Delete update", role: .destructive) { store.queueCommentDelete(task: task, commentId: commentId) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("More actions for your update")
                #if os(iOS)
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { store.queueCommentDelete(task: task, commentId: commentId) }
                    Button("Edit") {
                        composer = item.text
                        editingCommentId = commentId
                    }
                    .tint(accent)
                }
                #endif
            }
        }
    }

    private func load(page: Int, append: Bool) async {
        guard task.id > 0, let taskRef else { return }
        guard !store.commentOutbox.blocksRefresh(for: taskRef) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await VikunjaAPI.fetchCommentPage(taskId: task.id, page: page)
            if append {
                var merged = Dictionary(uniqueKeysWithValues: comments.map { ($0.id, $0) })
                for comment in result.items { merged[comment.id] = comment }
                comments = Array(merged.values)
            } else {
                comments = result.items
            }
            comments.sort { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }
            self.page = result.page
            hasEarlierPage = result.hasEarlierPage
            loadError = nil
        } catch {
            loadError = "Couldn’t load newer activity"
        }
    }


    private func timeText(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}
