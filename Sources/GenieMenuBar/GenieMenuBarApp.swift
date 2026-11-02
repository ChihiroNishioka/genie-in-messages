import AppKit
import Foundation
import GenieCore
import SwiftUI

@main
struct GenieMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            Text("ジーニー")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject, NSMenuDelegate {
    @Published var snapshot: EngineSnapshot?
    @Published var chats: [ChatSummary] = []
    @Published var phase = "起動しています"
    @Published var loginStatus = "確認中"
    @Published var symbol = "ジーニー"
    @Published var chatQuery = ""
    @Published var startupError: String?

    private let controller: GenieController?
    private let paths = ConfigPaths.default()
    private var refreshTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?
    @Published var notionTokenLabel = "未設定"

    override init() {
        do {
            controller = try GenieController(paths: paths)
            startupError = nil
        } catch {
            controller = nil
            startupError = "設定を読めませんでした"
            phase = "停止"
        }
        notionTokenLabel = NotionToken.statusLabel(NotionToken.status(at: paths.notionTokenFile))
        super.init()
        if let controller {
            LampIcon.menuLampLogger = FileGenieLog(url: controller.logURL)
        }
        begin()
    }

    func begin() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.loop()
        }
    }

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        applyStatusItem()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    func shutdown() {
        controller?.shutdown()
    }

    func onAppear() {
        Task {
            controller?.requestChatsRefresh()
            await refresh()
        }
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

    func toggleChat(id: Int64, guid: String) {
        guard let controller else { return }
        Task {
            await controller.engine.toggleChat(id: id, guid: guid)
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

    func refreshChats() async {
        guard let controller else { return }
        controller.requestChatsRefresh()
        chats = await controller.latestChats()
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
        symbol = LampIcon.statusLabel(for: LampIcon.appearance(for: snap))
        applyStatusItem()
        chats = await controller.latestChats()
    }

    private static func phaseText(_ snap: EngineSnapshot) -> String {
        if snap.paused { return "一時停止中" }
        if snap.lastError == "watch_start_failed" { return "imsg を起動できていません" }
        return "監視中"
    }

    private func applyStatusItem() {
        guard let button = statusItem?.button else { return }
        LampIcon.MenuBarStatus.apply(to: button, snapshot: snapshot)
        let image = button.image ?? NSImage()
        statusItem?.length = image.size.width > 0 ? image.size.width : NSStatusItem.squareLength
    }

    private func populate(_ menu: NSMenu) {
        func label(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        label("ジーニー")
        label(phase)
        label("同じApple IDのほかのMacでは動かさない")
        if let snap = snapshot, snap.screenLock == .locked || snap.heldLockCount > 0 {
            label("画面ロック中は送信を保留しています（\(snap.heldLockCount)件）")
        }
        if let snap = snapshot, snap.screenLock == .unknown {
            label("画面ロックを確認できていません")
        }
        if let snap = snapshot, !snap.webhookConfigured {
            label("webhook の URL が未設定です")
        }
        if let snap = snapshot, !snap.replyFetchConfigured {
            label("返事の取得先が未設定です")
        }
        menu.addItem(.separator())
        let pause = NSMenuItem(
            title: snapshot?.paused == true ? "再開" : "一時停止",
            action: #selector(togglePauseAction),
            keyEquivalent: ""
        )
        pause.target = self
        pause.isEnabled = !controllerMissing
        menu.addItem(pause)
        let allow = NSMenuItem(title: "トークの許可…", action: #selector(showAllowlist), keyEquivalent: "")
        allow.target = self
        allow.isEnabled = !controllerMissing
        menu.addItem(allow)
        if let halted = snapshot?.haltedChatIDs, !halted.isEmpty {
            let submenu = NSMenu()
            for chatID in halted {
                let item = NSMenuItem(title: "id:\(chatID) を再開", action: #selector(resumeRate(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: chatID)
                submenu.addItem(item)
            }
            let parent = NSMenuItem(title: "レート停止を解除", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        label("Notion トークン: \(notionTokenLabel)")
        let token = NSMenuItem(title: "Notion トークンを設定", action: #selector(promptNotionTokenAction), keyEquivalent: "")
        token.target = self
        menu.addItem(token)
        menu.addItem(.separator())
        label("最後のエラー: \(errorText)")
        label(SendHoldStatus.menuLine(for: snapshot?.holdNotice))
        let log = NSMenuItem(title: "ログを開く", action: #selector(openLogAction), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        let login = NSMenuItem(title: "ログイン時に起動: \(loginStatus)", action: #selector(toggleLoginAction), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "終了", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func togglePauseAction() { togglePause() }
    @objc private func showAllowlist() { AllowlistPanel.present(model: self) }
    @objc private func promptNotionTokenAction() { promptNotionToken() }
    @objc private func openLogAction() { openLog() }
    @objc private func toggleLoginAction() { toggleLoginItem() }
    @objc private func quitAction() { quit() }

    @objc private func resumeRate(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        resumeRateLimit(number.int64Value)
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
        case "reply_chat_guid_mismatch":
            return SendHoldStatus.text(for: code)
        case "reply_held_empty_list", "reply_held_not_in_list", "chats_failed", "chats_parse_failed", "chats_parse_partial_ok":
            return SendHoldStatus.text(for: code)
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
        default:
            return code ?? "なし"
        }
    }
}

extension AppModel {
    var controllerMissing: Bool { controller == nil }
}
