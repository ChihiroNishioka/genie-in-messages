import AppKit
import GenieCore
import SwiftUI

@MainActor
enum AllowlistPanel {
    private static var window: NSWindow?

    static func present(model: AppModel) {
        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            let host = NSHostingController(rootView: AllowlistView(model: model))
            let created = NSWindow(contentViewController: host)
            created.title = "トークの許可"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 440, height: 560))
            created.minSize = NSSize(width: 360, height: 320)
            created.isRestorable = false
            created.isReleasedWhenClosed = false
            created.hidesOnDeactivate = false
            created.level = .normal
            created.center()
            self.window = created
            window = created
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.refreshChats() }
    }
}

struct AllowlistView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let enabled = Set(model.snapshot?.enabledChatIDs ?? [])
        let configIDs = Set(model.snapshot?.configChatIDs ?? [])
        let rows = AllowlistOrdering.rows(chats: model.chats, enabledIDs: enabled, query: model.chatQuery, configIDs: configIDs)
        VStack(alignment: .leading, spacing: 10) {
            Text("オンにしたトークと設定で許可したグループだけ転送します。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("オンを上に、1対1をグループより上に並べています。名前か id で探せます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("名前か id で検索", text: $model.chatQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                Button("一覧を更新") {
                    Task { await model.refreshChats() }
                }
            }
            if let notice = configGroupNotice(notFound: model.snapshot?.configGroupNotFound ?? 0, notGroup: model.snapshot?.configGroupNotGroup ?? 0) {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if rows.isEmpty {
                Text(model.chats.isEmpty ? "トークはまだありません" : "一致するトークはありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            Button {
                                model.toggleChat(id: row.id, guid: row.guid)
                            } label: {
                                HStack(alignment: .center, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.title)
                                            .foregroundStyle(.primary)
                                        Text("\(row.kindLabel)  ·  id:\(row.id)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(row.enabled ? "オン" : "オフ")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(row.enabled ? Color.white : Color.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(row.enabled
                                            ? Color(red: 0.62, green: 0.42, blue: 0.08)
                                            : Color.gray.opacity(0.18))
                                        .clipShape(Capsule())
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(row.configLocked)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { searchFocused = true }
    }
}
