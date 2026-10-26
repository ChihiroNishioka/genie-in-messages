import Foundation

package actor GenieEngine {
    private let configProvider: any ConfigProviding
    private var config: GenieConfig
    private let stateStore: any StatePersisting
    private var persisted: PersistedState
    private let allowlistStore: any AllowlistPersisting
    private var allow: Set<Int64>
    private let replySource: any ReplySource
    private let sender: any MessageSending
    private let webhook: any WebhookPosting
    private let secrets: any SecretProviding
    private let lock: any ScreenLockChecking
    private let clock: any GenieClock
    private let log: any GenieLog

    private var paused = false
    private var holds: [HeldSend] = []
    private var screenLocked = false
    private var lastError: String?

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
        self.allow = try allowlistStore.load()
        self.replySource = replySource
        self.sender = sender
        self.webhook = webhook
        self.secrets = secrets
        self.lock = lock
        self.clock = clock
        self.log = log
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

    package func refreshLock() async {
        screenLocked = await lock.isLocked()
    }

    package func setChatEnabled(_ id: Int64, enabled: Bool) {
        if enabled {
            allow.insert(id)
        } else {
            allow.remove(id)
        }
        do {
            try allowlistStore.save(allow)
        } catch {
            lastError = "allowlist_save_failed"
            log.record(level: .error, code: "allowlist_save_failed", chatID: id, guid: nil, rowid: nil)
        }
        log.record(
            level: .info,
            code: enabled ? "allowlist_on" : "allowlist_off",
            chatID: id,
            guid: nil,
            rowid: nil
        )
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
            enabledChatIDs: allow.sorted(),
            haltedChatIDs: persisted.haltedChatIDs.sorted(),
            heldCount: holds.count,
            heldLockCount: holds.filter {
                $0.reason == .screenLocked || $0.reason == .appleEventNotStarted
            }.count,
            lastError: lastError,
            screenLocked: screenLocked,
            replyFetchConfigured: !config.replyFetchURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            webhookConfigured: !config.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    package func pollReplies() async {
        if paused { return }
        refreshConfig()
        let urlText = config.replyFetchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlText.isEmpty { return }
        do {
            let page = try await replySource.fetch(cursor: persisted.replyCursor)
            for reply in page.replies where reply.id.isEmpty {
                log.record(level: .error, code: "reply_missing_id", chatID: reply.chatID, guid: nil, rowid: nil)
            }
            for reply in page.replies where !reply.id.isEmpty {
                await deliverReply(reply)
            }
            let blocked = page.replies.contains { reply in
                !reply.id.isEmpty && !persisted.handledReplyIDs.contains(reply.id)
            }
            if !blocked, let next = page.nextCursor {
                persisted.replyCursor = next
                persist()
            }
        } catch ReplyFetchError.secretMode {
            lastError = "reply_secret_mode"
            log.record(level: .error, code: "reply_secret_mode", chatID: nil, guid: nil, rowid: nil)
        } catch {
            lastError = "reply_fetch_failed"
            log.record(level: .error, code: "reply_fetch_failed", chatID: nil, guid: nil, rowid: nil)
        }
    }

    package func retryHolds() async {
        if paused { return }
        refreshConfig()
        let due = holds
        holds = []
        let now = clock.now()
        for hold in due {
            if now < hold.nextAttemptAt {
                holds.append(hold)
                continue
            }
            await enqueueOrSend(
                replyID: hold.replyID,
                chatID: hold.chatID,
                text: hold.text,
                attempts: hold.attempts + 1
            )
        }
    }

    private func handle(_ event: WatchEvent) async -> IngestResult {
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
        if !event.isFromMe {
            return finish(event, .ignoredNotFromMe)
        }
        let normalized = TextNormalizer.nfc(event.text)
        if !Signal.matches(normalized) {
            return finish(event, .ignoredNoSignal)
        }
        guard let chatID = event.chatID, allow.contains(chatID) else {
            return finish(event, .ignoredNotAllowed)
        }
        if paused {
            return .deferredPaused
        }
        return await deliverWebhook(event: event, chatID: chatID, text: normalized)
    }

    private func deliverWebhook(event: WatchEvent, chatID: Int64, text: String) async -> IngestResult {
        let urlText = config.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlText.isEmpty, let url = URL(string: urlText) else {
            return deadLetter(event, error: "webhook_not_configured", attempts: 0)
        }
        let payload = WebhookPayload(
            v: 1,
            event: "message",
            idempotencyKey: event.guid,
            guid: event.guid,
            chatID: chatID,
            text: text,
            createdAt: event.createdAt
        )
        let body: Data
        do {
            body = try payload.encodeData()
        } catch {
            return deadLetter(event, error: "webhook_encode_failed", attempts: 0)
        }

        let maxAttempts = config.webhookMaxAttempts
        var last = "webhook_transport"
        var attempt = 0
        while attempt < maxAttempts {
            attempt += 1
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
            log.record(level: .error, code: "deadletter_write_failed", chatID: event.chatID, guid: event.guid, rowid: event.id)
        }
        lastError = error
        log.record(level: .error, code: error, chatID: event.chatID, guid: event.guid, rowid: event.id)
        return finish(event, .deadLettered(error))
    }

    private func deliverReply(_ reply: FetchedReply) async {
        if persisted.handledReplyIDs.contains(reply.id) { return }
        if holds.contains(where: { $0.replyID == reply.id }) { return }
        if config.marker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastError = "marker_empty"
            log.record(level: .error, code: "marker_empty", chatID: reply.chatID, guid: nil, rowid: nil)
            return
        }
        let prepared = ReplyComposer.prepare(body: reply.text, marker: config.marker)
        if Signal.matches(prepared) {
            markReplyHandled(reply.id)
            lastError = "reply_still_matches_signal"
            log.record(level: .error, code: "reply_still_matches_signal", chatID: reply.chatID, guid: nil, rowid: nil)
            persist()
            return
        }
        guard allow.contains(reply.chatID) else {
            markReplyHandled(reply.id)
            log.record(level: .info, code: "reply_chat_disabled", chatID: reply.chatID, guid: nil, rowid: nil)
            persist()
            return
        }
        if paused { return }
        await enqueueOrSend(replyID: reply.id, chatID: reply.chatID, text: prepared, attempts: 1)
    }

    private func enqueueOrSend(replyID: String, chatID: Int64, text: String, attempts: Int) async {
        let locked = await lock.isLocked()
        screenLocked = locked
        if locked {
            hold(replyID: replyID, chatID: chatID, text: text, reason: .screenLocked, attempts: attempts)
            lastError = "screen_locked"
            log.record(level: .error, code: "screen_locked", chatID: chatID, guid: nil, rowid: nil)
            return
        }
        if persisted.haltedChatIDs.contains(chatID) || !authorize(chatID: chatID, now: clock.now()) {
            if !persisted.haltedChatIDs.contains(chatID) {
                persisted.haltedChatIDs.append(chatID)
                persist()
            }
            hold(replyID: replyID, chatID: chatID, text: text, reason: .rateLimited, attempts: attempts)
            lastError = "rate_limited"
            log.record(level: .error, code: "rate_limited", chatID: chatID, guid: nil, rowid: nil)
            return
        }
        do {
            let receipt = try await sender.send(chatID: chatID, text: text)
            let now = clock.now()
            persisted.rateEvents.append(RateEvent(chatID: chatID, at: now))
            pruneRates(now: now)
            appendCapped(receipt.guid, to: &persisted.sentGUIDs)
            let hash = SHA256.hex(Data(text.utf8))
            persisted.fingerprints.append(SentFingerprint(hash: hash, sentAt: now))
            let cutoff = now.addingTimeInterval(-config.fingerprintWindowSeconds)
            persisted.fingerprints.removeAll { $0.sentAt < cutoff }
            holds.removeAll { $0.replyID == replyID }
            markReplyHandled(replyID)
            lastError = nil
            log.record(level: .info, code: "reply_sent", chatID: chatID, guid: receipt.guid, rowid: receipt.id)
            persist()
        } catch SendFailure.notStarted {
            hold(replyID: replyID, chatID: chatID, text: text, reason: .appleEventNotStarted, attempts: attempts)
            lastError = "apple_event_1712"
            log.record(level: .error, code: "apple_event_1712", chatID: chatID, guid: nil, rowid: nil)
        } catch SendFailure.uncertain {
            holds.removeAll { $0.replyID == replyID }
            markReplyHandled(replyID)
            lastError = "send_uncertain"
            log.record(level: .error, code: "send_uncertain", chatID: chatID, guid: nil, rowid: nil)
            persist()
        } catch {
            holds.removeAll { $0.replyID == replyID }
            markReplyHandled(replyID)
            lastError = "send_failed"
            log.record(level: .error, code: "send_failed", chatID: chatID, guid: nil, rowid: nil)
            persist()
        }
    }

    private func hold(replyID: String, chatID: Int64, text: String, reason: HoldReason, attempts: Int) {
        holds.removeAll { $0.replyID == replyID }
        holds.append(
            HeldSend(
                replyID: replyID,
                chatID: chatID,
                text: text,
                reason: reason,
                attempts: attempts,
                nextAttemptAt: clock.now().addingTimeInterval(config.holdRetryIntervalSeconds)
            )
        )
    }

    private func authorize(chatID: Int64, now: Date) -> Bool {
        pruneRates(now: now)
        let recent = persisted.rateEvents.filter {
            $0.chatID == chatID && now.timeIntervalSince($0.at) < config.rateLimitWindowSeconds
        }
        return recent.count < config.rateLimitCount
    }

    private func pruneRates(now: Date) {
        persisted.rateEvents.removeAll {
            now.timeIntervalSince($0.at) >= config.rateLimitWindowSeconds
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
        guard !id.isEmpty, !persisted.handledReplyIDs.contains(id) else { return }
        persisted.handledReplyIDs.append(id)
        if persisted.handledReplyIDs.count > 5000 {
            persisted.handledReplyIDs.removeFirst(persisted.handledReplyIDs.count - 5000)
        }
    }

    private func appendCapped(_ guid: String, to list: inout [String]) {
        guard !guid.isEmpty, !list.contains(guid) else { return }
        list.append(guid)
        if list.count > 5000 {
            list.removeFirst(list.count - 5000)
        }
    }

    private func persist() {
        do {
            try stateStore.save(persisted)
        } catch {
            lastError = "state_save_failed"
            log.record(level: .error, code: "state_save_failed", chatID: nil, guid: nil, rowid: nil)
        }
    }

    private func refreshConfig() {
        do {
            config = try configProvider.load().sanitized()
        } catch {
            lastError = "config_unreadable"
            log.record(level: .error, code: "config_unreadable", chatID: nil, guid: nil, rowid: nil)
        }
    }

    private func secretCode(_ error: SecretReadError) -> String {
        switch error {
        case .missing: return "secret_missing"
        case .insecureMode: return "secret_mode"
        case .empty: return "secret_empty"
        case .unreadable: return "secret_unreadable"
        }
    }
}
