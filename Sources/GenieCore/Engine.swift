import Foundation

package actor GenieEngine {
    private let configProvider: any ConfigProviding
    private var config: GenieConfig
    private let stateStore: any StatePersisting
    private var persisted: PersistedState
    private let allowlistStore: any AllowlistPersisting
    private var allowlist: AllowlistState
    private let replySource: any ReplySource
    private let sender: any MessageSending
    private let webhook: any WebhookPosting
    private let secrets: any SecretProviding
    private let lock: any ScreenLockChecking
    private let clock: any GenieClock
    private let log: any GenieLog

    private var paused = false
    private var holds: [HeldSend] = []
    /// `imsg chats` の `last_addressed_handle`。失敗した読み直しでは残す。
    private var directoryHandleKeys: Set<String> = []
    /// watch の `destination_caller_id`。chats が読めなくても残る。
    private var watchHandleKeys: Set<String> = []
    private var directoryChats: [Int64: DirectoryChat] = [:]
    /// 直近の一覧で見えた chat_id とその guid。空の guid は入れない。
    private var directoryGUIDs: [Int64: String] = [:]
    /// 起動後、最初の一覧照合が終わるまでは返事を取らない。
    private var directoryChecked = false
    private var inFlightReplyIDs: Set<String> = []

    private struct DirectoryChat {
        var isGroup: Bool
        var participantsKnown: Bool
        var participants: [String]
    }
    private var screenLock: ScreenLockState = .unknown
    private var lastError: String?
    /// 照合できずに送らなかった理由。最後のエラーとは別で、ほかのエラーを上書きしない。
    private var holdNotice: String?
    /// この取得で、まだ待っている返事があった。
    private var notedHoldThisPass = false
    private var loggedMarkerReplacement = false

    package init(
        configProvider: any ConfigProviding,
        initialConfig: GenieConfig,
        stateStore: any StatePersisting,
        allowlistStore: any AllowlistPersisting,
        replySource: any ReplySource,
        sender: any MessageSending,
        webhook: any WebhookPosting,
        secrets: any SecretProviding,
        lock: any ScreenLockChecking,
        clock: any GenieClock = SystemClock(),
        log: any GenieLog
    ) throws {
        self.configProvider = configProvider
        self.config = initialConfig.sanitized()
        self.stateStore = stateStore
        self.persisted = try stateStore.load()
        self.allowlistStore = allowlistStore
        self.allowlist = try allowlistStore.load()
        self.replySource = replySource
        self.sender = sender
        self.webhook = webhook
        self.secrets = secrets
        self.lock = lock
        self.clock = clock
        self.log = log
        var loaded = persisted
        Self.settleInterrupted(state: &loaded, store: stateStore, log: log, now: clock.now(), window: config.rateLimitWindowSeconds)
        persisted = loaded
        if config.markerWasReplaced {
            log.record(level: .warning, code: "marker_replaced", chatID: nil, guid: nil, rowid: nil)
            loggedMarkerReplacement = true
        }
    }

    package func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    package func isPaused() -> Bool { paused }

    package func setLastError(_ code: String?) {
        lastError = code
        if let code {
            log.record(level: .error, code: code, chatID: nil, guid: nil, rowid: nil)
        }
    }

    /// メニューのコードは `watch_exited` / `watch_start_failed` のまま。内訳は detail に残す。
    /// 一時停止や終了で止めたときはログだけ残し、メニューの最後のエラーは変えない。
    package func noteWatchEnded(_ result: WatchRunResult, updateMenu: Bool = true) {
        let code = result.reason == WatchEndReason.startFailed ? "watch_start_failed" : "watch_exited"
        if updateMenu {
            lastError = code
        }
        log.record(
            level: updateMenu ? .error : .info,
            code: code,
            chatID: nil,
            guid: nil,
            rowid: persisted.cursorRowID,
            detail: result.logDetail(rowid: persisted.cursorRowID)
        )
    }

    package func noteLock(_ state: ScreenLockState) {
        let becameUnlocked = screenLock != .unlocked && state == .unlocked
        screenLock = state
        guard becameUnlocked else { return }
        let now = clock.now()
        for index in holds.indices where holds[index].reason == .screenLocked {
            holds[index].nextAttemptAt = now
        }
    }

    package func refreshLock() async {
        noteLock(await lock.state())
    }

    /// いまの許可から反転する。連打はアクターの中で順に効く。
    /// 一覧外の行は guid を持たないので、オンに戻すときは知っている guid を使う。
    package func toggleChat(id: Int64, guid: String) {
        let enabled = !allowlist.contains(id)
        let resolved: String
        if enabled && guid.isEmpty {
            resolved = persisted.knownChats.first { $0.id == id }?.guid ?? ""
        } else {
            resolved = guid
        }
        if enabled && resolved.isEmpty {
            log.record(level: .warning, code: "allowlist_guid_unknown", chatID: id, guid: nil, rowid: nil)
        }
        setChatEnabled(id, guid: resolved, enabled: enabled)
    }

    package func setChatEnabled(_ id: Int64, guid: String = "", enabled: Bool) {
        let previous = allowlist
        allowlist.entries.removeAll { $0.id == id }
        if enabled {
            allowlist.entries.append(AllowedChat(id: id, guid: guid))
        }
        do {
            try allowlistStore.save(allowlist)
        } catch {
            allowlist = previous
            lastError = "allowlist_save_failed"
            log.record(level: .error, code: "allowlist_save_failed", chatID: id, guid: nil, rowid: nil)
            return
        }
        log.record(
            level: .info,
            code: enabled ? "allowlist_on" : "allowlist_off",
            chatID: id,
            guid: nil,
            rowid: nil
        )
    }

    package func reconcileChats(_ chats: [ChatSummary]) {
        var facts: [Int64: DirectoryChat] = [:]
        for chat in chats {
            facts[chat.id] = DirectoryChat(
                isGroup: chat.isGroup,
                participantsKnown: chat.participantsKnown,
                participants: chat.participants
            )
        }
        directoryChats = facts
        directoryHandleKeys = SelfChat.ownHandleKeys(in: chats)
        var guids: [Int64: String] = [:]
        for chat in chats where !chat.guid.isEmpty {
            guids[chat.id] = chat.guid
        }
        directoryGUIDs = guids
        directoryChecked = true
        clearRecoveredListError()
        for chat in chats where !chat.guid.isEmpty {
            if observeChat(id: chat.id, guid: chat.guid) {
                return
            }
        }
    }

    /// `imsg chats` の失敗。標準出力も標準エラーも残さない。
    /// 一覧を確かめられなかったので、そのあいだは返事を送らない。
    package func noteChatsProblem(code: String, updateMenu: Bool) {
        directoryGUIDs = [:]
        directoryChecked = false
        // 定期取得は updateMenu を false にする。一覧が読めないと返事を送れないので、照合の表示には出す。
        if updateMenu || code == "chats_failed" || code == "chats_parse_failed" {
            holdNotice = code
        }
        log.record(
            level: .error,
            code: code,
            chatID: nil,
            guid: nil,
            rowid: nil
        )
    }

    /// 一覧を読み直せたら、照合の表示だけを消す。最後のエラーは残す。
    private func clearRecoveredListError() {
        if allowlistVerified() {
            holdNotice = nil
            return
        }
        switch holdNotice {
        case "chats_failed", "chats_parse_failed":
            holdNotice = nil
        default:
            break
        }
    }

    /// 許可したトークの guid が、いまの一覧と一致している。
    private func allowlistVerified() -> Bool {
        guard directoryChecked else { return false }
        for entry in allowlist.entries {
            let current = directoryGUIDs[entry.id] ?? ""
            if entry.guid.isEmpty || current.isEmpty || current != entry.guid {
                return false
            }
        }
        return true
    }

    /// 待っていた返事が期限切れでなくなったとき、その照合の表示だけを消す。
    private func clearExpiredHoldNotice() {
        switch holdNotice {
        case "reply_held_empty_list", "reply_held_not_in_list", "chats_failed", "chats_parse_failed":
            holdNotice = nil
        default:
            break
        }
    }

    package func resumeRateLimit(chatID: Int64) async {
        persisted.haltedChatIDs.removeAll { $0 == chatID }
        let now = clock.now()
        for index in holds.indices where holds[index].chatID == chatID && holds[index].reason == .rateLimited {
            holds[index].nextAttemptAt = now
        }
        persist()
        await retryHolds()
    }

    package func snapshot() -> EngineSnapshot {
        EngineSnapshot(
            paused: paused,
            cursorRowID: persisted.cursorRowID,
            enabledChatIDs: allowlist.ids.sorted(),
            haltedChatIDs: persisted.haltedChatIDs.sorted(),
            heldCount: holds.count,
            heldLockCount: holds.filter {
                $0.reason == .screenLocked || $0.reason == .appleEventNotStarted
            }.count,
            lastError: lastError,
            holdNotice: holdNotice,
            screenLocked: screenLock == .locked,
            screenLock: screenLock,
            replyFetchConfigured: !config.notionDataSourceID.isEmpty
                || EndpointURL.https(config.replyFetchURL) != nil,
            webhookConfigured: EndpointURL.https(config.webhookURL) != nil
        )
    }

    package func ingestWatchLine(_ line: String) async -> IngestResult {
        refreshConfig()
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .skipped
        }
        if paused {
            return .deferredPaused
        }
        guard let event = WatchEvent.decode(line) else {
            log.record(level: .error, code: "watch_not_json", chatID: nil, guid: nil, rowid: nil)
            return .notJSON
        }
        return await handle(event)
    }

    package func noteOversizedWatchLine(rowID: Int64?) -> IngestResult {
        log.record(level: .error, code: "watch_line_too_large", chatID: nil, guid: nil, rowid: rowID)
        guard let rowID else {
            lastError = "watch_line_too_large"
            return .blocked
        }
        let entry = DeadLetterEntry(
            ts: ISO8601.string(from: clock.now()),
            kind: "watch",
            chatID: nil,
            guid: nil,
            rowid: rowID,
            attempts: 0,
            error: "watch_line_too_large"
        )
        do {
            try stateStore.appendDeadLetter(entry)
        } catch {
            lastError = "deadletter_write_failed"
            log.record(level: .error, code: "deadletter_write_failed", chatID: nil, guid: nil, rowid: rowID)
            return .blocked
        }
        if rowID > persisted.cursorRowID {
            persisted.cursorRowID = rowID
        }
        lastError = "watch_line_too_large"
        persist()
        return .skipped
    }

    package func pollReplies() async {
        // 一覧と許可の guid を比べる前に取りに行くと、入れ替わった番号へ送ることがある。
        guard directoryChecked else { return }
        if paused { return }
        notedHoldThisPass = false
        refreshConfig()
        let notion = !config.notionDataSourceID.isEmpty
        let rawURL = config.replyFetchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notion {
            if rawURL.isEmpty { return }
            guard EndpointURL.https(rawURL) != nil else {
                lastError = "url_not_https"
                log.record(level: .error, code: "url_not_https", chatID: nil, guid: nil, rowid: nil)
                return
            }
        }
        do {
            let holding = Set(holds.map(\.replyID)).union(inFlightReplyIDs)
            let page = try await replySource.fetch(
                cursor: persisted.replyCursor,
                skipping: Set(persisted.handledReplyIDs),
                holding: holding
            )
            if page.skipped > 0 {
                log.record(level: .error, code: "reply_bad_entry", chatID: nil, guid: nil, rowid: nil)
            }
            let freshCount = page.replies.filter { !holding.contains($0.id) }.count
            if freshCount > config.replyPageLimit {
                log.record(level: .error, code: "reply_page_over_limit", chatID: nil, guid: nil, rowid: nil)
            }
            for reply in page.replies {
                await deliverReply(reply)
            }
            let unhandled = page.replies.filter { reply in
                !reply.id.isEmpty && !persisted.handledReplyIDs.contains(reply.id)
            }
            if let proposed = page.nextCursor {
                let next: String?
                if NotionCursor.decode(proposed) != nil {
                    next = NotionCursor.reconcile(proposed: proposed, unhandled: unhandled)
                } else if unhandled.isEmpty {
                    next = proposed
                } else {
                    next = nil
                }
                if let next, next != persisted.replyCursor {
                    persisted.replyCursor = next
                    persist()
                }
            }
            if !notedHoldThisPass {
                clearExpiredHoldNotice()
            }
        } catch ReplyFetchError.secretMode {
            lastError = "reply_secret_mode"
            log.record(level: .error, code: "reply_secret_mode", chatID: nil, guid: nil, rowid: nil)
        } catch ReplyFetchError.notionToken(let error) {
            let code = notionTokenCode(error)
            lastError = code
            log.record(level: .error, code: code, chatID: nil, guid: nil, rowid: nil)
        } catch {
            lastError = "reply_fetch_failed"
            log.record(level: .error, code: "reply_fetch_failed", chatID: nil, guid: nil, rowid: nil)
        }
    }

    package func retryHolds() async {
        guard directoryChecked else { return }
        if paused { return }
        refreshConfig()
        let now = clock.now()
        var ready: [HeldSend] = []
        var kept: [HeldSend] = []
        for hold in holds {
            if now < hold.nextAttemptAt || inFlightReplyIDs.contains(hold.replyID) {
                kept.append(hold)
                continue
            }
            inFlightReplyIDs.insert(hold.replyID)
            ready.append(hold)
        }
        holds = kept
        for hold in ready {
            if clock.now().timeIntervalSince(hold.createdAt) > config.routeTTLSeconds {
                inFlightReplyIDs.remove(hold.replyID)
                markReplyHandled(hold.replyID)
                log.record(level: .info, code: "reply_too_old", chatID: hold.chatID, guid: nil, rowid: nil)
                persist()
                continue
            }
            await performSend(
                replyID: hold.replyID,
                chatID: hold.chatID,
                text: hold.text,
                attempts: hold.attempts + 1,
                reserved: true,
                pauseReason: hold.reason,
                createdAt: hold.createdAt,
                originGUID: hold.originGUID
            )
        }
    }

    private func handle(_ event: WatchEvent) async -> IngestResult {
        if let chatID = event.chatID, let guid = event.chatGUID, !guid.isEmpty {
            if observeChat(id: chatID, guid: guid) {
                return .ignoredDatabaseReset
            }
        }
        if event.isMutation {
            log.record(level: .info, code: "ignored_mutation", chatID: event.chatID, guid: event.guid, rowid: event.id)
            return .ignoredMutation
        }
        if event.isReaction {
            return finish(event, .ignoredReaction)
        }
        if !event.guid.isEmpty, persisted.sentGUIDs.contains(event.guid) {
            return finish(event, .ignoredSentGUID)
        }
        if !event.guid.isEmpty, persisted.seenGUIDs.contains(event.guid) {
            return finish(event, .duplicate)
        }
        if fingerprintMatches(text: event.text, createdAt: event.createdAt) {
            return finish(event, .ignoredFingerprint)
        }
        let normalized = TextNormalizer.nfc(event.text)
        if !Signal.matches(normalized) {
            return finish(event, .ignoredNoSignal)
        }
        guard let chatID = event.chatID, allowlist.contains(chatID) else {
            return finish(event, .ignoredNotAllowed)
        }
        if let key = SenderHandle.normalize(event.destinationCallerID) {
            watchHandleKeys.insert(key)
        }
        let echoed = echoParticipants(for: event)
        if !event.isFromMe && SelfChat.ignoresInboundEcho(
            isGroup: echoed.isGroup,
            chatID: event.chatID,
            participantsKnown: echoed.participantsKnown,
            participants: echoed.participants,
            ownHandles: directoryHandleKeys.union(watchHandleKeys),
            forcedSelfChatIDs: Set(config.selfChatIDs)
        ) {
            return finish(event, .ignoredNotFromMe)
        }
        if paused {
            return .deferredPaused
        }
        return await deliverWebhook(
            event: event,
            chatID: chatID,
            text: normalized,
            senderIsMe: event.isFromMe,
            senderName: payloadSenderName(event)
        )
    }

    /// watch の行に participants が無いときは、直近の chats のその chat_id を使う。
    private func echoParticipants(for event: WatchEvent) -> (isGroup: Bool, participantsKnown: Bool, participants: [String]) {
        let stored = event.chatID.flatMap { directoryChats[$0] }
        let isGroup = event.isGroup || (stored?.isGroup ?? false)
        if event.participantsKnown {
            return (isGroup, true, event.participants)
        }
        if let stored, stored.participantsKnown {
            return (isGroup, true, stored.participants)
        }
        return (isGroup, false, [])
    }

    /// 表示名。対応表が無くても、ここは反応の可否を変えない。ハンドルは返さない。
    private func payloadSenderName(_ event: WatchEvent) -> String {
        if event.isFromMe {
            return config.selfSenderName
        }
        if let mapped = config.displayName(matching: event.sender) {
            return mapped
        }
        let contact = event.contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        if TextNormalizer.isBlank(contact) { return "" }
        if SelfChat.isHandle(contact, sender: event.sender) { return "" }
        return contact
    }

    private func deliverWebhook(
        event: WatchEvent,
        chatID: Int64,
        text: String,
        senderIsMe: Bool,
        senderName: String
    ) async -> IngestResult {
        let rawURL = config.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawURL.isEmpty {
            return deadLetter(event, error: "webhook_not_configured", attempts: 0)
        }
        guard let url = EndpointURL.https(rawURL) else {
            return deadLetter(event, error: "url_not_https", attempts: 0)
        }
        let payload = WebhookPayload(
            v: 1,
            event: "message",
            idempotencyKey: event.guid,
            guid: event.guid,
            chatID: chatID,
            text: text,
            createdAt: event.createdAt,
            senderIsMe: senderIsMe,
            senderName: senderName
        )
        let body: Data
        do {
            body = try payload.encodeData()
        } catch {
            return deadLetter(event, error: "webhook_encode_failed", attempts: 0)
        }
        if !event.guid.isEmpty {
            rememberRoute(guid: event.guid, chatID: chatID)
            if !persist() {
                return .blocked
            }
        }

        let maxAttempts = config.webhookMaxAttempts
        var last = "webhook_transport"
        var attempt = 0
        while attempt < maxAttempts {
            attempt += 1
            if paused {
                return .deferredPaused
            }
            if !allowlist.contains(chatID) {
                log.record(level: .info, code: "webhook_chat_disabled", chatID: chatID, guid: event.guid, rowid: event.id)
                return finish(event, .ignoredNotAllowed)
            }
            let token: String
            do {
                token = try secrets.webhookSecret()
            } catch let error as SecretReadError {
                let code = secretCode(error)
                if code == "secret_mode" || code == "secret_missing" || code == "secret_empty" {
                    return deadLetter(event, error: code, attempts: attempt)
                }
                last = code
                if attempt < maxAttempts, await sleepBackoff(attempt: attempt) == false {
                    return .deferredPaused
                }
                continue
            } catch {
                last = "secret_unreadable"
                if attempt < maxAttempts, await sleepBackoff(attempt: attempt) == false {
                    return .deferredPaused
                }
                continue
            }
            if paused {
                return .deferredPaused
            }
            if !allowlist.contains(chatID) {
                log.record(level: .info, code: "webhook_chat_disabled", chatID: chatID, guid: event.guid, rowid: event.id)
                return finish(event, .ignoredNotAllowed)
            }
            do {
                let response = try await webhook.post(
                    url: url,
                    secret: token,
                    body: body,
                    idempotencyKey: event.guid
                )
                if (200...299).contains(response.statusCode) {
                    lastError = nil
                    log.record(level: .info, code: "webhook_delivered", chatID: chatID, guid: event.guid, rowid: event.id)
                    return finish(event, .delivered)
                }
                last = "webhook_http_\(response.statusCode)"
                if !WebhookRetry.shouldRetry(statusCode: response.statusCode) {
                    return deadLetter(event, error: last, attempts: attempt)
                }
            } catch {
                last = "webhook_transport"
            }
            if attempt < maxAttempts {
                if await sleepBackoff(attempt: attempt) == false {
                    return .deferredPaused
                }
            }
        }
        return deadLetter(event, error: last, attempts: attempt)
    }

    private func sleepBackoff(attempt: Int) async -> Bool {
        let delay = WebhookRetry.delay(
            attempt: attempt,
            initial: config.webhookInitialBackoffSeconds,
            cap: config.webhookMaxBackoffSeconds
        )
        do {
            try await clock.sleep(seconds: delay)
        } catch {
            return false
        }
        return !paused
    }

    private func deadLetter(_ event: WatchEvent, error: String, attempts: Int) -> IngestResult {
        let entry = DeadLetterEntry(
            ts: ISO8601.string(from: clock.now()),
            kind: "webhook",
            chatID: event.chatID,
            guid: event.guid.isEmpty ? nil : event.guid,
            rowid: event.id,
            attempts: attempts,
            error: error
        )
        do {
            try stateStore.appendDeadLetter(entry)
        } catch {
            lastError = "deadletter_write_failed"
            log.record(level: .error, code: "deadletter_write_failed", chatID: event.chatID, guid: event.guid, rowid: event.id)
            return .blocked
        }
        lastError = error
        log.record(level: .error, code: error, chatID: event.chatID, guid: event.guid, rowid: event.id)
        return finish(event, .deadLettered(error))
    }

    private func deliverReply(_ reply: FetchedReply) async {
        if reply.id.isEmpty {
            log.record(level: .error, code: "reply_missing_id", chatID: reply.chatID, guid: nil, rowid: nil)
            return
        }
        if persisted.handledReplyIDs.contains(reply.id) { return }
        if holds.contains(where: { $0.replyID == reply.id }) { return }
        if inFlightReplyIDs.contains(reply.id) { return }
        guard let origin = reply.inReplyToGUID?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty,
              let createdAt = reply.createdAt?.trimmingCharacters(in: .whitespacesAndNewlines), !createdAt.isEmpty,
              let created = ISO8601.date(from: createdAt) else {
            log.record(level: .error, code: "reply_missing_fields", chatID: reply.chatID, guid: nil, rowid: nil)
            markReplyHandled(reply.id)
            persist()
            return
        }
        if clock.now().timeIntervalSince(created) > config.routeTTLSeconds {
            log.record(level: .info, code: "reply_too_old", chatID: reply.chatID, guid: nil, rowid: nil)
            markReplyHandled(reply.id)
            persist()
            return
        }
        guard let route = route(for: origin) else {
            log.record(level: .info, code: "reply_unrouted", chatID: reply.chatID, guid: nil, rowid: nil)
            markReplyHandled(reply.id)
            persist()
            return
        }
        if let sourceChat = reply.chatID, sourceChat != route.chatID {
            log.record(level: .error, code: "reply_chat_mismatch", chatID: reply.chatID, guid: nil, rowid: nil)
            markReplyHandled(reply.id)
            persist()
            return
        }
        let chatID = route.chatID
        if !allowlist.contains(chatID) {
            log.record(level: .info, code: "reply_chat_disabled", chatID: chatID, guid: nil, rowid: nil)
            markReplyHandled(reply.id)
            persist()
            return
        }
        let prepared = ReplyComposer.prepare(body: reply.text, marker: config.marker)
        if Signal.matches(prepared) {
            markReplyHandled(reply.id)
            lastError = "reply_still_matches_signal"
            log.record(level: .error, code: "reply_still_matches_signal", chatID: chatID, guid: nil, rowid: nil)
            persist()
            return
        }
        if paused { return }
        await performSend(
            replyID: reply.id,
            chatID: chatID,
            text: prepared,
            attempts: 1,
            reserved: false,
            pauseReason: .appleEventNotStarted,
            createdAt: created,
            originGUID: origin
        )
    }

    private func performSend(
        replyID: String,
        chatID: Int64,
        text: String,
        attempts: Int,
        reserved: Bool,
        pauseReason: HoldReason,
        createdAt: Date,
        originGUID: String
    ) async {
        if !reserved {
            guard inFlightReplyIDs.insert(replyID).inserted else { return }
        }
        defer { inFlightReplyIDs.remove(replyID) }

        refreshConfig()
        if paused {
            hold(replyID: replyID, chatID: chatID, text: text, reason: pauseReason, attempts: attempts, logIt: false, immediate: true, createdAt: createdAt, originGUID: originGUID)
            return
        }
        guard allowlist.contains(chatID) else {
            dropDisabled(replyID: replyID, chatID: chatID)
            return
        }
        if rejectMismatchedChatGuid(replyID: replyID, chatID: chatID) { return }
        let locked = await lock.state()
        noteLock(locked)
        refreshConfig()
        if paused {
            hold(replyID: replyID, chatID: chatID, text: text, reason: pauseReason, attempts: attempts, logIt: false, immediate: true, createdAt: createdAt, originGUID: originGUID)
            return
        }
        guard allowlist.contains(chatID) else {
            dropDisabled(replyID: replyID, chatID: chatID)
            return
        }
        if rejectMismatchedChatGuid(replyID: replyID, chatID: chatID) { return }
        if locked == .locked {
            let first = attempts == 1 && !holds.contains { $0.replyID == replyID }
            hold(replyID: replyID, chatID: chatID, text: text, reason: .screenLocked, attempts: attempts, logIt: first, createdAt: createdAt, originGUID: originGUID)
            if first {
                lastError = "screen_locked"
            }
            return
        }
        if persisted.haltedChatIDs.contains(chatID) || !authorize(chatID: chatID, now: clock.now()) {
            let newlyHalted = !persisted.haltedChatIDs.contains(chatID)
            if newlyHalted {
                persisted.haltedChatIDs.append(chatID)
                persist()
                lastError = "rate_limited"
                log.record(level: .error, code: "rate_limited", chatID: chatID, guid: nil, rowid: nil)
            }
            hold(replyID: replyID, chatID: chatID, text: text, reason: .rateLimited, attempts: attempts, logIt: false, createdAt: createdAt, originGUID: originGUID)
            return
        }
        let reservedAt = clock.now()
        countRate(chatID: chatID, at: reservedAt)
        recordIntent(replyID: replyID, chatID: chatID, text: text, at: reservedAt, rateCounted: true)
        if !persist() {
            releaseRate(chatID: chatID, at: reservedAt)
            rollbackIntent(replyID: replyID)
            hold(replyID: replyID, chatID: chatID, text: text, reason: .appleEventNotStarted, attempts: attempts, logIt: false, createdAt: createdAt, originGUID: originGUID)
            return
        }
        if paused {
            releaseRate(chatID: chatID, at: reservedAt)
            rollbackIntent(replyID: replyID)
            persist()
            hold(replyID: replyID, chatID: chatID, text: text, reason: pauseReason, attempts: attempts, logIt: false, immediate: true, createdAt: createdAt, originGUID: originGUID)
            return
        }
        if !allowlist.contains(chatID) {
            releaseRate(chatID: chatID, at: reservedAt)
            rollbackIntent(replyID: replyID)
            dropDisabled(replyID: replyID, chatID: chatID)
            return
        }
        if rejectMismatchedChatGuid(replyID: replyID, chatID: chatID) {
            releaseRate(chatID: chatID, at: reservedAt)
            rollbackIntent(replyID: replyID)
            persist()
            return
        }
        do {
            let receipt = try await sender.send(chatID: chatID, text: text)
            finishIntent(replyID: replyID)
            appendCapped(receipt.guid, to: &persisted.sentGUIDs)
            holds.removeAll { $0.replyID == replyID }
            markReplyHandled(replyID)
            lastError = nil
            log.record(level: .info, code: "reply_sent", chatID: chatID, guid: receipt.guid, rowid: receipt.id)
            persist()
        } catch SendFailure.notStarted {
            releaseRate(chatID: chatID, at: reservedAt)
            rollbackIntent(replyID: replyID)
            hold(replyID: replyID, chatID: chatID, text: text, reason: .appleEventNotStarted, attempts: attempts, logIt: attempts == 1, createdAt: createdAt, originGUID: originGUID)
            if attempts == 1 {
                lastError = "apple_event_1712"
            }
            persist()
        } catch SendFailure.uncertain {
            holds.removeAll { $0.replyID == replyID }
            markReplyHandled(replyID)
            if recordReplyDeadLetter(replyID: replyID, chatID: chatID, error: "send_uncertain") {
                finishIntent(replyID: replyID)
            }
            lastError = "send_uncertain"
            log.record(level: .error, code: "send_uncertain", chatID: chatID, guid: nil, rowid: nil)
            persist()
        } catch {
            releaseRate(chatID: chatID, at: reservedAt)
            rollbackIntent(replyID: replyID)
            holds.removeAll { $0.replyID == replyID }
            if recordReplyDeadLetter(replyID: replyID, chatID: chatID, error: "send_failed") {
                markReplyHandled(replyID)
                persist()
            } else {
                hold(replyID: replyID, chatID: chatID, text: text, reason: .appleEventNotStarted, attempts: attempts, logIt: false, createdAt: createdAt, originGUID: originGUID)
                persist()
            }
            lastError = "send_failed"
            log.record(level: .error, code: "send_failed", chatID: chatID, guid: nil, rowid: nil)
        }
    }

    /// そのトークの guid を一覧で確かめられたときだけ送る。
    /// 一覧が空、その id が無い、取得に失敗、guid が違う、のいずれも送らない。
    /// 理由はメニューとログに出す。番号、メール、識別子は出さない。
    private func rejectMismatchedChatGuid(replyID: String, chatID: Int64) -> Bool {
        let current = directoryGUIDs[chatID] ?? ""
        let allowed = allowlist.entries.first { $0.id == chatID }?.guid ?? ""
        if directoryChecked && !current.isEmpty && !allowed.isEmpty && current == allowed {
            return false
        }
        let code = holdReasonCode(current: current, allowed: allowed)
        if !current.isEmpty && !allowed.isEmpty && current != allowed {
            holds.removeAll { $0.replyID == replyID }
            markReplyHandled(replyID)
            persist()
        }
        noteHold(code)
        return true
    }

    private func holdReasonCode(current: String, allowed: String) -> String {
        if !directoryChecked {
            return "chats_failed"
        }
        if !current.isEmpty && !allowed.isEmpty && current != allowed {
            return "reply_chat_guid_mismatch"
        }
        if directoryGUIDs.isEmpty {
            return "reply_held_empty_list"
        }
        return "reply_held_not_in_list"
    }

    private func noteHold(_ code: String) {
        let changed = holdNotice != code
        holdNotice = code
        notedHoldThisPass = true
        guard changed else { return }
        log.record(level: .error, code: code, chatID: nil, guid: nil, rowid: nil)
    }

    private func dropDisabled(replyID: String, chatID: Int64) {
        holds.removeAll { $0.replyID == replyID }
        markReplyHandled(replyID)
        lastError = "reply_chat_disabled"
        log.record(level: .info, code: "reply_chat_disabled", chatID: chatID, guid: nil, rowid: nil)
        persist()
    }

    private func hold(
        replyID: String,
        chatID: Int64,
        text: String,
        reason: HoldReason,
        attempts: Int,
        logIt: Bool,
        immediate: Bool = false,
        createdAt: Date,
        originGUID: String
    ) {
        holds.removeAll { $0.replyID == replyID }
        let delay = immediate ? 0 : config.holdRetryIntervalSeconds
        holds.append(
            HeldSend(
                replyID: replyID,
                chatID: chatID,
                text: text,
                reason: reason,
                attempts: attempts,
                nextAttemptAt: clock.now().addingTimeInterval(delay),
                createdAt: createdAt,
                originGUID: originGUID
            )
        )
        if logIt {
            log.record(level: .error, code: reason.rawValue, chatID: chatID, guid: nil, rowid: nil)
        }
    }

    private func authorize(chatID: Int64, now: Date) -> Bool {
        pruneRates(now: now)
        let recent = persisted.rateEvents.filter {
            $0.chatID == chatID && now.timeIntervalSince($0.at) < config.rateLimitWindowSeconds
        }
        return recent.count < config.rateLimitCount
    }

    private func countRate(chatID: Int64, at: Date? = nil) {
        let now = at ?? clock.now()
        persisted.rateEvents.append(RateEvent(chatID: chatID, at: now))
        pruneRates(now: clock.now())
    }

    private func releaseRate(chatID: Int64, at: Date) {
        if let index = persisted.rateEvents.lastIndex(where: { $0.chatID == chatID && $0.at == at }) {
            persisted.rateEvents.remove(at: index)
        }
    }

    private func pruneRates(now: Date) {
        persisted.rateEvents.removeAll {
            now.timeIntervalSince($0.at) >= config.rateLimitWindowSeconds
        }
    }

    private func recordIntent(replyID: String, chatID: Int64, text: String, at: Date, rateCounted: Bool) {
        let hash = SHA256.hex(Data(TextNormalizer.nfc(text).utf8))
        persisted.pendingSends.removeAll { $0.replyID == replyID }
        persisted.pendingSends.append(
            PendingSend(replyID: replyID, chatID: chatID, hash: hash, at: at, rateCounted: rateCounted)
        )
        cap(&persisted.pendingSends)
        persisted.fingerprints.append(SentFingerprint(hash: hash, sentAt: at))
        pruneFingerprints(now: at)
    }

    private func rollbackIntent(replyID: String) {
        guard let pending = persisted.pendingSends.first(where: { $0.replyID == replyID }) else { return }
        persisted.pendingSends.removeAll { $0.replyID == replyID }
        persisted.fingerprints.removeAll { $0.hash == pending.hash && $0.sentAt == pending.at }
    }

    private func finishIntent(replyID: String) {
        persisted.pendingSends.removeAll { $0.replyID == replyID }
    }

    private static func settleInterrupted(
        state: inout PersistedState,
        store: any StatePersisting,
        log: any GenieLog,
        now: Date,
        window: Double
    ) {
        let pending = state.pendingSends
        guard !pending.isEmpty else { return }
        var kept: [PendingSend] = []
        for item in pending {
            let entry = DeadLetterEntry(
                ts: ISO8601.string(from: now),
                kind: "reply",
                chatID: item.chatID,
                guid: nil,
                rowid: nil,
                attempts: 1,
                error: "send_interrupted"
            )
            var wrote = false
            do {
                try store.appendDeadLetter(entry)
                wrote = true
            } catch {
                log.record(level: .error, code: "deadletter_write_failed", chatID: item.chatID, guid: nil, rowid: nil)
            }
            if !state.fingerprints.contains(where: { $0.hash == item.hash && $0.sentAt == item.at }) {
                state.fingerprints.append(SentFingerprint(hash: item.hash, sentAt: item.at))
            }
            if !item.rateCounted {
                state.rateEvents.append(RateEvent(chatID: item.chatID, at: item.at))
            }
            if !item.replyID.isEmpty, !state.handledReplyIDs.contains(item.replyID) {
                state.handledReplyIDs.append(item.replyID)
            }
            if wrote {
                log.record(level: .error, code: "send_interrupted", chatID: item.chatID, guid: nil, rowid: nil)
            } else {
                var copy = item
                copy.rateCounted = true
                kept.append(copy)
            }
        }
        HandledReplyIDs.prune(&state.handledReplyIDs, protecting: NotionCursor.ids(in: state.replyCursor))
        state.pendingSends = kept
        state.rateEvents.removeAll { now.timeIntervalSince($0.at) >= window }
        do {
            try store.save(state)
        } catch {
            log.record(level: .error, code: "state_save_failed", chatID: nil, guid: nil, rowid: nil)
        }
    }

    private func recordReplyDeadLetter(replyID: String, chatID: Int64, error: String) -> Bool {
        let entry = DeadLetterEntry(
            ts: ISO8601.string(from: clock.now()),
            kind: "reply",
            chatID: chatID,
            guid: nil,
            rowid: nil,
            attempts: 1,
            error: error
        )
        do {
            try stateStore.appendDeadLetter(entry)
            return true
        } catch {
            lastError = "deadletter_write_failed"
            log.record(level: .error, code: "deadletter_write_failed", chatID: chatID, guid: nil, rowid: nil)
            return false
        }
    }

    private func fingerprintMatches(text: String, createdAt: String?) -> Bool {
        if text.isEmpty { return false }
        let hash = SHA256.hex(Data(TextNormalizer.nfc(text).utf8))
        let now = clock.now()
        let messageTime = ISO8601.date(from: createdAt) ?? now
        let window = config.fingerprintWindowSeconds
        return persisted.fingerprints.contains { fingerprint in
            fingerprint.hash == hash && abs(messageTime.timeIntervalSince(fingerprint.sentAt)) <= window
        }
    }

    private func pruneFingerprints(now: Date) {
        let cutoff = now.addingTimeInterval(-config.fingerprintWindowSeconds)
        persisted.fingerprints.removeAll { $0.sentAt < cutoff }
    }

    private func finish(_ event: WatchEvent, _ result: IngestResult) -> IngestResult {
        if !event.guid.isEmpty {
            appendCapped(event.guid, to: &persisted.seenGUIDs)
        }
        if event.id > persisted.cursorRowID {
            persisted.cursorRowID = event.id
        }
        persist()
        return result
    }

    private func markReplyHandled(_ id: String) {
        HandledReplyIDs.insert(
            id,
            into: &persisted.handledReplyIDs,
            protecting: NotionCursor.ids(in: persisted.replyCursor)
        )
    }

    private func appendCapped(_ guid: String, to list: inout [String]) {
        guard !guid.isEmpty, !list.contains(guid) else { return }
        list.append(guid)
        if list.count > 5000 {
            list.removeFirst(list.count - 5000)
        }
    }

    private func cap(_ routes: inout [PendingSend]) {
        if routes.count > 5000 {
            routes.removeFirst(routes.count - 5000)
        }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try stateStore.save(persisted)
            return true
        } catch {
            lastError = "state_save_failed"
            log.record(level: .error, code: "state_save_failed", chatID: nil, guid: nil, rowid: nil)
            return false
        }
    }

    private func refreshConfig() {
        do {
            config = try configProvider.load().sanitized()
            noteMarkerReplacement(config)
        } catch {
            lastError = "config_unreadable"
            log.record(level: .error, code: "config_unreadable", chatID: nil, guid: nil, rowid: nil)
        }
    }

    /// 印を既定に戻しているあいだは、このプロセスで警告を1回だけ出す。
    /// 設定を直したあとに再び戻す状態になったときは、もう1回出す。
    private func noteMarkerReplacement(_ loaded: GenieConfig) {
        if loaded.markerWasReplaced {
            if !loggedMarkerReplacement {
                log.record(level: .warning, code: "marker_replaced", chatID: nil, guid: nil, rowid: nil)
                loggedMarkerReplacement = true
            }
        } else {
            loggedMarkerReplacement = false
        }
    }

    private func rememberRoute(guid: String, chatID: Int64) {
        let now = clock.now()
        persisted.routes.removeAll {
            $0.guid == guid || now.timeIntervalSince($0.at) > config.routeTTLSeconds
        }
        persisted.routes.append(MessageRoute(guid: guid, chatID: chatID, at: now))
        if persisted.routes.count > 5000 {
            persisted.routes.removeFirst(persisted.routes.count - 5000)
        }
    }

    private func route(for guid: String) -> MessageRoute? {
        let now = clock.now()
        return persisted.routes.first {
            $0.guid == guid && now.timeIntervalSince($0.at) <= config.routeTTLSeconds
        }
    }

    private func observeChat(id: Int64, guid: String) -> Bool {
        if let known = persisted.knownChats.first(where: { $0.id == id }), known.guid != guid {
            resetForDatabaseSwap(ChatIdentity(id: id, guid: guid))
            return true
        }
        if !persisted.knownChats.contains(where: { $0.id == id }) {
            persisted.knownChats.append(ChatIdentity(id: id, guid: guid))
            if persisted.knownChats.count > 5000 {
                persisted.knownChats.removeFirst(persisted.knownChats.count - 5000)
            }
            persist()
        }
        if let index = allowlist.entries.firstIndex(where: { $0.id == id }) {
            let bound = allowlist.entries[index].guid
            if bound.isEmpty {
                allowlist.entries[index].guid = guid
                do {
                    try allowlistStore.save(allowlist)
                } catch {
                    allowlist.entries[index].guid = ""
                    lastError = "allowlist_save_failed"
                    log.record(level: .error, code: "allowlist_save_failed", chatID: id, guid: nil, rowid: nil)
                }
            } else if bound != guid {
                resetForDatabaseSwap(ChatIdentity(id: id, guid: guid))
                return true
            }
        }
        return false
    }

    private func resetForDatabaseSwap(_ identity: ChatIdentity) {
        persisted.knownChats = [identity]
        persisted.cursorRowID = 0
        persisted.routes = []
        persisted.pendingSends = []
        holds.removeAll()
        allowlist = .empty
        do {
            try allowlistStore.save(allowlist)
        } catch {
            log.record(level: .error, code: "allowlist_save_failed", chatID: identity.id, guid: nil, rowid: nil)
        }
        persist()
        lastError = "messages_db_reset"
        log.record(level: .error, code: "messages_db_reset", chatID: identity.id, guid: nil, rowid: nil)
    }

    private func secretCode(_ error: SecretReadError) -> String {
        switch error {
        case .missing: return "secret_missing"
        case .insecureMode: return "secret_mode"
        case .empty: return "secret_empty"
        case .unreadable: return "secret_unreadable"
        }
    }

    private func notionTokenCode(_ error: SecretReadError) -> String {
        switch error {
        case .missing: return "notion_token_missing"
        case .insecureMode: return "notion_token_mode"
        case .empty: return "notion_token_empty"
        case .unreadable: return "notion_token_unreadable"
        }
    }
}

enum HandledReplyIDs {
    static let cap = 5000

    static func insert(_ id: String, into ids: inout [String], protecting: Set<String>) {
        guard !id.isEmpty, !ids.contains(id) else { return }
        ids.append(id)
        prune(&ids, protecting: protecting)
    }

    static func prune(_ ids: inout [String], protecting: Set<String>) {
        guard ids.count > cap else { return }
        var protected: [String] = []
        var rest: [String] = []
        for id in ids {
            if protecting.contains(id) {
                protected.append(id)
            } else {
                rest.append(id)
            }
        }
        let protectedKept = protected.count > cap ? Array(protected.suffix(cap)) : protected
        let room = max(0, cap - protectedKept.count)
        if rest.count > room {
            rest.removeFirst(rest.count - room)
        }
        var merged = rest + protectedKept
        if merged.count > cap {
            merged = Array(merged.suffix(cap))
        }
        ids = merged
    }
}
