import AppKit
import Foundation
import GenieCore
import SwiftUI

@main
struct GenieMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            Text(model.symbol)
                .onAppear { model.begin() }
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: EngineSnapshot?
    @Published var chats: [ChatSummary] = []
    @Published var phase = "起動しています"
    @Published var loginStatus = "確認中"
    @Published var symbol = "🧞"
    @Published var startupError: String?

    private let controller: GenieController?
    private let paths = ConfigPaths.default()
    private var refreshTask: Task<Void, Never>?
    private var lastChatRefresh = Date.distantPast
    @Published var notionTokenLabel = "未設定"

    init() {
        do {
            controller = try GenieController(paths: paths)
            startupError = nil
        } catch {
            controller = nil
            startupError = "設定を読めませんでした"
            phase = "停止"
        }
        notionTokenLabel = NotionToken.statusLabel(NotionToken.status(at: paths.notionTokenFile))
        begin()
    }

    func begin() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.loop()
        }
    }

    func onAppear() {
        Task { await refreshChats(reportError: true) }
    }

    func togglePause() {
        guard let controller else { return }
        Task {
            if await controller.engine.isPaused() {
                await controller.resume()
            } else {
                await controller.pause()
            }
            await refresh()
        }
    }

    func toggleChat(_ chat: ChatSummary) {
        guard let controller, let snapshot else { return }
        let enabled = !snapshot.enabledChatIDs.contains(chat.id)
        Task {
            await controller.engine.setChatEnabled(chat.id, guid: chat.guid, enabled: enabled)
            await refresh()
        }
    }

    func resumeRateLimit(_ chatID: Int64) {
        guard let controller else { return }
        Task {
            await controller.engine.resumeRateLimit(chatID: chatID)
            await refresh()
        }
    }

    func refreshChats(reportError: Bool = true) async {
        guard let controller else { return }
        chats = await controller.loadChats(reportError: reportError)
        lastChatRefresh = Date()
    }

    func toggleLoginItem() {
        let enable = loginStatus != "オン"
        do {
            try LoginItemController.setEnabled(enable)
        } catch {
            Task { await controller?.engine.setLastError("login_item_failed") }
        }
        loginStatus = LoginItemController.statusText()
    }

    func openLog() {
        guard let controller else { return }
        let url = controller.logURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            )
        }
        NSWorkspace.shared.open(url)
    }

    func promptNotionToken() {
        let alert = NSAlert()
        alert.messageText = "Notion トークン"
        alert.informativeText = "内部連携のトークンを入力します。保存後は画面に出しません。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entered = field.stringValue
        field.stringValue = ""
        do {
            try NotionToken.save(entered, to: paths.notionTokenFile)
            notionTokenLabel = NotionToken.statusLabel(NotionToken.status(at: paths.notionTokenFile))
        } catch let error as SecretReadError {
            let code = error == .empty ? "notion_token_empty" : "notion_token_unreadable"
            Task { await controller?.engine.setLastError(code) }
        } catch {
            Task { await controller?.engine.setLastError("notion_token_unreadable") }
        }
    }

    func quit() {
        controller?.shutdown()
        NSApp.terminate(nil)
    }

    private func loop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func refresh() async {
        guard let controller else { return }
        let snap = await controller.engine.snapshot()
        snapshot = snap
        loginStatus = LoginItemController.statusText()
        notionTokenLabel = NotionToken.statusLabel(NotionToken.status(at: paths.notionTokenFile))
        phase = Self.phaseText(snap)
        symbol = Self.symbol(for: snap)
        if Date().timeIntervalSince(lastChatRefresh) >= 30 {
            chats = await controller.loadChats(reportError: false)
            lastChatRefresh = Date()
        }
    }

    private static func phaseText(_ snap: EngineSnapshot) -> String {
        if snap.paused { return "一時停止中" }
        if snap.lastError == "watch_start_failed" { return "imsg を起動できていません" }
        return "監視中"
    }

    private static func symbol(for snap: EngineSnapshot) -> String {
        let warning = snap.screenLock != .unlocked
            || snap.heldLockCount > 0
            || !snap.haltedChatIDs.isEmpty
            || snap.lastError == "watch_start_failed"
        if warning { return "🧞⚠" }
        if snap.paused { return "🧞⏸" }
        return "🧞"
    }

    var errorText: String {
        if let startupError { return startupError }
        return Self.describe(snapshot?.lastError)
    }

    static func describe(_ code: String?) -> String {
        switch code {
        case nil, "":
            return "なし"
        case "screen_locked":
            return "画面ロック中のため送信を保留しています"
        case "screen_lock_unknown":
            return "画面ロックを確認できていません"
        case "url_not_https":
            return "webhook と返事の URL は https だけ使えます"
        case "messages_db_reset":
            return "メッセージのデータベースが変わったため、許可とカーソルを捨てました"
        case "reply_unrouted":
            return "対応する転送が無い返事は送っていません"
        case "reply_chat_mismatch":
            return "返事のトークが転送先と違うため送っていません"
        case "watch_line_too_large":
            return "大きすぎる watch の行を処理できませんでした"
        case "deadletter_write_failed":
            return "失敗の記録を書けませんでした"
        case "send_interrupted":
            return "送信の途中で止まったため、再送していません"
        case "apple_event_1712":
            return "送信が始まらなかったため保留しています"
        case "rate_limited":
            return "送信レートの上限で、そのトークへの返信を止めています"
        case "secret_mode":
            return "secret の権限が 600 ではありません"
        case "secret_missing":
            return "webhook の secret がありません"
        case "secret_empty":
            return "webhook の secret が空です"
        case "webhook_not_configured":
            return "webhook の URL が未設定です"
        case "watch_start_failed":
            return "imsg を起動できませんでした"
        case "watch_exited":
            return "imsg watch が終了したので再起動します"
        case "send_uncertain":
            return "送信結果が不明なため、再送していません"
        case "send_failed":
            return "送信に失敗しました。結果が不明なので再送していません"
        case "reply_fetch_failed":
            return "返事の取得に失敗しました"
        case "reply_secret_mode":
            return "reply-secret の権限が 600 ではありません"
        case "notion_token_missing":
            return "Notion トークンがありません"
        case "notion_token_mode":
            return "Notion トークンの権限が 600 ではありません"
        case "notion_token_empty":
            return "Notion トークンが空です"
        case "notion_token_unreadable":
            return "Notion トークンを保存できませんでした"
        case "state_reset":
            return "壊れていた状態ファイルを退避し、今から監視しています"
        case "allowlist_reset":
            return "壊れていた許可リストを退避し、すべてオフに戻しました"
        case "login_item_failed":
            return "ログイン時の起動を切り替えられませんでした"
        case "caffeinate_failed":
            return "caffeinate を起動できませんでした"
        case "chats_failed":
            return "トーク一覧を読めませんでした"
        default:
            return code ?? "なし"
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Text("ジーニー")
        Text(model.phase)
        Text("同じApple IDのほかのMacでは動かさない")
            .font(.caption)
        if let snap = model.snapshot, snap.screenLock == .locked || snap.heldLockCount > 0 {
            Text("画面ロック中は送信を保留しています（\(snap.heldLockCount)件）")
        }
        if let snap = model.snapshot, snap.screenLock == .unknown {
            Text("画面ロックを確認できていません")
        }
        if let snap = model.snapshot, !snap.webhookConfigured {
            Text("webhook の URL が未設定です")
        }
        if let snap = model.snapshot, !snap.replyFetchConfigured {
            Text("返事の取得先が未設定です")
        }
        Divider()
        Button(model.snapshot?.paused == true ? "再開" : "一時停止") {
            model.togglePause()
        }
        .disabled(model.controllerMissing)
        Menu("トークの許可") {
            Text("初期状態はすべてオフ")
            Button("一覧を更新") { Task { await model.refreshChats(reportError: true) } }
            if model.chats.isEmpty {
                Text("トークはまだありません")
            }
            ForEach(model.chats) { chat in
                let on = model.snapshot?.enabledChatIDs.contains(chat.id) == true
                Button((on ? "オン  " : "オフ  ") + chat.title + (chat.isGroup ? "（グループ）" : "") + "  id:\(chat.id)") {
                    model.toggleChat(chat)
                }
            }
        }
        if let halted = model.snapshot?.haltedChatIDs, !halted.isEmpty {
            Menu("レート停止を解除") {
                ForEach(halted, id: \.self) { chatID in
                    Button("id:\(chatID) を再開") { model.resumeRateLimit(chatID) }
                }
            }
        }
        Divider()
        Text("Notion トークン: \(model.notionTokenLabel)")
        Button("Notion トークンを設定") { model.promptNotionToken() }
        Divider()
        Text("最後のエラー: \(model.errorText)")
        Button("ログを開く") { model.openLog() }
        Button("ログイン時に起動: \(model.loginStatus)") { model.toggleLoginItem() }
        Divider()
        Button("終了") { model.quit() }
    }
}

extension AppModel {
    var controllerMissing: Bool { controller == nil }
}
