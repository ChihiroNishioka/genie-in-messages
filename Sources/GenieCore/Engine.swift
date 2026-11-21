import Foundation

private enum MarkerAttempt {
    case image(path: String)
    case text(String)

    var kind: MarkerKind {
        switch self {
        case .image: .image
        case .text: .text
        }
    }

    var detail: String {
        kind == .image ? "marker_image" : "marker"
    }
}

private enum OutboundSelfEvidence: Equatable {
    case participant(String)
    case selfChatIDs

    var kind: OutboundSelfEvidenceKind {
        switch self {
        case .participant: .participant
        case .selfChatIDs: .selfChatIDs
        }
    }
}

package actor GenieEngine {
    private let configProvider: any ConfigProviding
    private var config: GenieConfig
    private let stateStore: any StatePersisting
    private var persisted: PersistedState
    private let allowlistStore: any AllowlistPersisting
    private var allowlist: AllowlistState
    private let httpReplySource: (any ReplySource)?
    private let outboundSource: any OutboundSource
    private var outboundPersistenceBlocked = false
    private var outboundFetching = false
    private var outboundNextFetchAt: Date?
    private var outboundPollWanted = true
    private var outboundDirectory: [ChatSummary] = []
    private var outboundParticipantEvidence: [String: String] = [:]
    private let replySource: any ReplySource
    private let sender: any MessageSending
    private let markerImage: any MarkerImageLocating
    private let webhook: any WebhookPosting
    private let secrets: any SecretProviding
    private let lock: any ScreenLockChecking
    private let clock: any GenieClock
    private let log: any GenieLog
    private let stop: StopSignal

    private var paused = false
    private var holds: [HeldSend] = []
    /// `imsg chats` の `last_addressed_handle`。失敗した読み直しでは残す。
    private var directoryHandleKeys: Set<String> = []
    /// watch の `destination_caller_id`。chats が読めなくても残る。
    private var watchHandleKeys: Set<String> = []
    private var configGroups = ConfigGroupAuthorization()
    private var directoryChats: [Int64: DirectoryChat] = [:]
    /// 直近の一覧で見えた chat_id とその guid。空の guid は入れない。
    private var directoryGUIDs: [Int64: String] = [:]
    /// 起動後、最初の一覧照合が終わるまでは返事を取らない。
    private var directoryChecked = false
    private var inFlightReplyIDs: Set<String> = []
    private var inFlightReplyChats: [String: Int64] = [:]
    private var chatWaitingReplyIDs: Set<String> = []
    private var bodyResendSavePending: Set<String> = []
    private var outboundIntentFingerprints: [String: (String, Date)] = [:]
    private var databaseGeneration = 0

    private struct DirectoryChat {
        var isGroup: Bool
        var participantsKnown: Bool
        var participants: [String]
    }
    private var screenLock: ScreenLockState = .unknown
    private var lastError: String?
    private var replyFetchErrors: [ReplyLane: String] = [:]
    /// 取得障害の開始時刻。最初の失敗で置き、成功するまで上書きしない。
    private var listFetchFailingSince: Date?
    private var parseProblem: ParseProblem?
    /// 直近の取得成功で、許可したトークを確かめられたか。失敗のあいだは前の値を保つ。
    private var lastFetchVerified = false
    /// 一覧が空、または一覧に無い、で待っている返事。
    private var transientHold: String?
    /// guid が違って捨てた返事がある。確かめられるまで残す。
    private var guidMismatchOutstanding = false
    private var noticeLog = NoticeLogGate()
    /// 間隔を待たずに、次の tick で返事を取る。
    private var replyPollWanted = false
    /// この取得で、期限切れにして捨てた返事があった。
    private var expiredReplyThisPass = false
    /// この取得で、まだ待っている返事があった。
    private var notedHoldThisPass = false

    package init(
        configProvider: any ConfigProviding,
        initialConfig: GenieConfig,
        stateStore: any StatePersisting,
        allowlistStore: any AllowlistPersisting,
        replySource: any ReplySource,
        httpReplySource: (any ReplySource)? = nil,
        outboundSource: any OutboundSource = EmptyOutboundSource(),
        sender: any MessageSending,
        markerImage: any MarkerImageLocating,
        webhook: any WebhookPosting,
        secrets: any SecretProviding,
        lock: any ScreenLockChecking,
        clock: any GenieClock = SystemClock(),
        log: any GenieLog,
        stop: StopSignal = StopSignal()
    ) throws {
        self.configProvider = configProvider
        self.config = initialConfig.sanitized()
        self.stateStore = stateStore
        self.persisted = try stateStore.load()
        self.allowlistStore = allowlistStore
        self.allowlist = try allowlistStore.load()
        self.httpReplySource = httpReplySource
        self.replySource = replySource
        self.outboundSource = outboundSource
        self.sender = sender
        self.markerImage = markerImage
        self.webhook = webhook
        self.secrets = secrets
        self.lock = lock
        self.clock = clock
        self.log = log
        self.stop = stop
        var loaded = persisted
        self.outboundPersistenceBlocked = !Self.settleOutboundInterrupted(state: &loaded, store: stateStore, log: log, now: clock.now())
        Self.settleInterrupted(state: &loaded, store: stateStore, log: log, now: clock.now(), window: config.rateLimitWindowSeconds)
        persisted = loaded
    }

    package func setPaused(_ paused: Bool) {
        let wasPaused = self.paused
        self.paused = paused
        if wasPaused && !paused {
            replyPollWanted = true
            outboundPollWanted = true
        }
    }

    package func isReplyPollWanted() -> Bool { replyPollWanted }

    package func inFlightReplyCount() -> Int { inFlightReplyIDs.count }

    package func savedReplyCursor() -> String? { persisted.replyCursor }

    package static let chatsFailureNoticeSeconds: Double = 60

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
        refreshConfig()
        if configGroups.intentChatIDs.contains(id) {
            log.record(level: .info, code: "allowlist_off_config_locked", chatID: id, guid: nil, rowid: nil)
            return
        }
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
        refreshConfig()
        if configGroups.intentChatIDs.contains(id) {
            log.record(level: .info, code: "allowlist_off_config_locked", chatID: id, guid: nil, rowid: nil)
            return
        }
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

    /// 一覧の読み取り結果を反映する。止まっていたら、状態を変えずに捨てる。
    package func applyChatList(_ read: ChatListRead) -> ChatListApplyResult {
        if stop.isStopped { return .discarded }
        if paused { refreshConfig(forPausedDisplay: true) }
        switch read {
        case .failed:
            noteFetchFailure()
            return .applied([])
        case .parsed(let parsed):
            noteFetchSuccess()
            if parsed.chats.isEmpty && parsed.failedLineCount > 0 {
                parseProblem = .allRows
                lastFetchVerified = false
                directoryGUIDs = [:]
                directoryChecked = false
                logListCode("chats_parse_failed")
                return .applied([])
            }
            reconcileChats(parsed.chats)
            let verified = allowlistVerified()
            lastFetchVerified = verified
            if parsed.failedLineCount > 0 {
                parseProblem = .partial
                if verified { clearWaitingLayers() }
                logListCode("chats_parse_failed")
            } else if verified {
                parseProblem = nil
                noticeLog.resolve(["chats_parse_failed"])
                clearWaitingLayers()
            }
            return .applied(parsed.chats)
        }
    }

    package func reconcileChats(_ chats: [ChatSummary]) {
        noteFetchSuccess()
        outboundDirectory = chats
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
        let becameChecked = !directoryChecked
        directoryChecked = true
        if becameChecked { replyPollWanted = true; outboundPollWanted = true }
        var reset = false
        for chat in chats where !chat.guid.isEmpty {
            if observeChat(id: chat.id, guid: chat.guid) {
                reset = true
                break
            }
        }
        if !reset {
            configGroups.observe(chats, guids: config.groupChatGUIDs)
            noteConfigGroups()
            if allowlistVerified() {
                lastFetchVerified = true
                clearWaitingLayers()
            } else {
                lastFetchVerified = false
            }
        }
    }

    private func noteFetchFailure() {
        if listFetchFailingSince == nil {
            listFetchFailingSince = clock.now()
        }
        directoryGUIDs = [:]
        directoryChecked = false
        logListCode("chats_failed")
    }

    private func noteFetchSuccess() {
        if listFetchFailingSince != nil {
            listFetchFailingSince = nil
            noticeLog.resolve(["chats_failed"])
        }
    }

    private func clearWaitingLayers() {
        if let code = transientHold {
            transientHold = nil
            noticeLog.resolve([code])
        }
        if guidMismatchOutstanding {
            guidMismatchOutstanding = false
            noticeLog.resolve(["reply_chat_guid_mismatch"])
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

    /// 期限切れで返事を捨てたとき、一時的な保留だけを消す。
    private func clearExpiredHoldNotice() {
        guard let code = transientHold else { return }
        transientHold = nil
        noticeLog.resolve([code])
    }

    private func composedHoldNotice(now: Date) -> String? {
        if let since = listFetchFailingSince,
           now.timeIntervalSince(since) >= Self.chatsFailureNoticeSeconds {
            return "chats_failed"
        }
        switch parseProblem {
        case .allRows:
            return "chats_parse_failed"
        case .partial:
            return lastFetchVerified ? "chats_parse_partial_ok" : "chats_parse_failed"
        case nil:
            break
        }
        if let transientHold { return transientHold }
        if guidMismatchOutstanding { return "reply_chat_guid_mismatch" }
        return nil
    }

    private func logListCode(_ code: String) {
        guard noticeLog.shouldLog(code) else { return }
        log.record(level: .error, code: code, chatID: nil, guid: nil, rowid: nil)
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
        if paused { refreshConfig(forPausedDisplay: true) }
        return EngineSnapshot(
            paused: paused,
            cursorRowID: persisted.cursorRowID,
            enabledChatIDs: allowlist.ids.union(configGroups.resolved.keys).sorted(),
            haltedChatIDs: persisted.haltedChatIDs.sorted(),
            heldCount: holds.count,
            heldLockCount: holds.filter {
                $0.reason == .screenLocked || $0.reason == .appleEventNotStarted
            }.count,
            lastError: lastError,
            replyFetchError: replyFetchErrors[.http] ?? replyFetchErrors[.legacyHTTP] ?? replyFetchErrors[.notion],
            holdNotice: composedHoldNotice(now: clock.now()),
            screenLocked: screenLock == .locked,
            screenLock: screenLock,
            replyFetchConfigured: !config.notionDataSourceID.isEmpty
                || EndpointURL.httpsOrLoopback(config.replyFetchURL) != nil,
            jobWebhookConfigured: !config.jobChatIDs.isEmpty
                && EndpointURL.httpsOrLoopback(config.jobWebhookURL) != nil,
            jobRouteState: JobRouteState(config: config),
            webhookConfigured: EndpointURL.https(config.webhookURL) != nil,
            configChatIDs: configGroups.intentChatIDs.sorted(),
            configGroupUnresolved: configGroups.notFound + configGroups.notGroup,
            configGroupNotFound: configGroups.notFound,
            configGroupNotGroup: configGroups.notGroup
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

    private enum ReplyLane {
        case http, notion, legacyHTTP

        var detail: String { self == .notion ? "notion" : "http" }
    }

    @discardableResult
    package func pollReplies() async -> ReplyPollOutcome {
        if stop.isStopped { return .skippedStopped }
        // 一覧と許可の guid を比べる前に取りに行くと、入れ替わった番号へ送ることがある。
        guard directoryChecked else { return .skippedUnchecked }
        if paused { return .skippedPaused }
        notedHoldThisPass = false
        expiredReplyThisPass = false
        refreshConfig()
        prunePartialReplies()
        let pollConfig = config
        let notion = !pollConfig.notionDataSourceID.isEmpty
        let rawURL = pollConfig.replyFetchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let dual = notion && !rawURL.isEmpty
        var sources: [(ReplyLane, any ReplySource)] = []
        if dual {
            if let httpReplySource { sources.append((.http, httpReplySource)) }
            sources.append((.notion, replySource))
        } else if notion {
            sources.append((.notion, replySource))
        } else if !rawURL.isEmpty {
            sources.append((.legacyHTTP, replySource))
        }
        let lanes = sources.map { lane, source in
            let savedCursor = lane == .http ? persisted.httpReplyCursor : persisted.replyCursor
            return (lane, source.prepared(for: pollConfig), savedCursor)
        }
        replyFetchErrors = replyFetchErrors.filter { key, _ in sources.contains { $0.0 == key } }
        if lanes.isEmpty { return finishReplyPoll(.notConfigured) }
        let holding = Set(holds.map(\.replyID)).union(inFlightReplyIDs).union(chatWaitingReplyIDs)
        var clearedWaiting = false
        var failed = false
        for (lane, source, savedCursor) in lanes {
            if stop.isStopped { return .skippedStopped }
            let detail: String? = dual ? lane.detail : nil
            if lane != .notion && EndpointURL.httpsOrLoopback(rawURL) == nil {
                replyFetchErrors[lane] = "url_not_https"
                log.record(level: .error, code: "url_not_https", chatID: nil, guid: nil, rowid: nil, detail: detail)
                failed = true
                continue
            }
            do {
                let cursor = lane == .legacyHTTP && NotionCursor.decode(savedCursor) != nil ? nil : savedCursor
                let page = try await source.fetch(
                    cursor: cursor,
                    skipping: Set(persisted.handledReplyIDs),
                    holding: holding
                )
                if stop.isStopped { return .skippedStopped }
                replyFetchErrors.removeValue(forKey: lane)
                if !clearedWaiting {
                    chatWaitingReplyIDs.removeAll()
                    clearedWaiting = true
                }
                if page.skipped > 0 {
                    log.record(level: .error, code: "reply_bad_entry", chatID: nil, guid: nil, rowid: nil)
                }
                let freshCount = page.replies.filter { !holding.contains($0.id) }.count
                if freshCount > pollConfig.replyPageLimit {
                    log.record(level: .error, code: "reply_page_over_limit", chatID: nil, guid: nil, rowid: nil)
                }
                for reply in page.replies {
                    if stop.isStopped { return .skippedStopped }
                    await deliverReply(reply)
                    if stop.isStopped { return .skippedStopped }
                }
                let unhandled = page.replies.filter { reply in
                    !reply.id.isEmpty && !persisted.handledReplyIDs.contains(reply.id)
                }
                if let proposed = page.nextCursor {
                    let next: String?
                    if lane == .notion {
                        next = NotionCursor.reconcile(proposed: proposed, unhandled: unhandled)
                    } else if unhandled.isEmpty {
                        next = proposed
                    } else {
                        next = nil
                    }
                    if let next, next != savedCursor {
                        if lane == .http {
                            persisted.httpReplyCursor = next
                        } else {
                            persisted.replyCursor = next
                        }
                        persist()
                    }
                }
            } catch {
                if stop.isStopped { return .skippedStopped }
                let code: String
                switch error {
                case ReplyFetchError.secretMode: code = "reply_secret_mode"
                case ReplyFetchError.notionToken(let error): code = notionTokenCode(error)
                default: code = "reply_fetch_failed"
                }
                replyFetchErrors[lane] = code
                log.record(level: .error, code: code, chatID: nil, guid: nil, rowid: nil, detail: detail)
                failed = true
            }
        }
        if expiredReplyThisPass && !notedHoldThisPass {
            clearExpiredHoldNotice()
        }
        return finishReplyPoll(failed ? .fetchFailed : .fetched)
    }

    private func finishReplyPoll(_ outcome: ReplyPollOutcome) -> ReplyPollOutcome {
        switch outcome {
        case .fetched, .fetchFailed, .notConfigured:
            replyPollWanted = false
        case .skippedUnchecked, .skippedPaused, .skippedStopped:
            break
        }
        return outcome
    }

    package func retryHolds() async {
        retryOutboundDeadLetters()
        if stop.isStopped { return }
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
                inFlightReplyChats[hold.replyID] = hold.chatID
            ready.append(hold)
        }
        holds = kept
        for (index, hold) in ready.enumerated() {
            if stop.isStopped || !directoryChecked {
                let remaining = Array(ready[index...])
                holds.append(contentsOf: remaining)
                for item in remaining {
                    inFlightReplyIDs.remove(item.replyID)
                    inFlightReplyChats.removeValue(forKey: item.replyID)
                }
                return
            }
            if !isOutbound(hold.replyID) && clock.now().timeIntervalSince(hold.createdAt) > config.routeTTLSeconds {
                inFlightReplyIDs.remove(hold.replyID)
                inFlightReplyChats.removeValue(forKey: hold.replyID)
                markReplyHandled(hold.replyID)
                persisted.partialReplies.removeAll { $0.replyID == hold.replyID }
                bodyResendSavePending.remove(hold.replyID)
                log.record(level: .info, code: "reply_too_old", chatID: hold.chatID, guid: nil, rowid: nil)
                persist()
                continue
            }
            await performSend(
                replyID: hold.replyID,
                chatID: hold.chatID,
                part: hold.part,
                body: hold.body,
                attempts: hold.attempts + 1,
                reserved: true,
                pauseReason: hold.reason,
                createdAt: hold.createdAt,
                origin: hold.origin
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
        if ReplyComposer.isReplyMarker(normalized, marker: config.replyMarker) {
            return finish(event, .ignoredReplyMarker)
        }
        let requestText: String?
        if Signal.matches(normalized) {
            requestText = nil
        } else if let chatID = event.chatID, isDoveChat(chatID, guid: event.chatGUID) {
            let dove = DoveSignal.scan(normalized)
            guard dove.matched else { return finish(event, .ignoredNoSignal) }
            requestText = dove.remainder
        } else {
            return finish(event, .ignoredNoSignal)
        }
        guard let chatID = event.chatID, allowsReceive(chatID, guid: event.chatGUID) else {
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
        if let requestText {
            guard !TextNormalizer.isBlank(requestText) else { return finish(event, .ignoredEmptyDove) }
            guard !event.guid.isEmpty else { return finish(event, .ignoredMissingDoveGUID) }
        }
        return await deliverWebhook(
            event: event,
            chatID: chatID,
            text: normalized,
            requestText: requestText,
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
        requestText: String?,
        senderIsMe: Bool,
        senderName: String
    ) async -> IngestResult {
        let trigger: ReplyTrigger = requestText == nil ? .lamp : .dove
        let job = trigger == .lamp && config.jobChatIDs.contains(chatID) && !config.jobWebhookURL.isEmpty
        let rawURL = (job ? config.jobWebhookURL : config.webhookURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = job ? "job_webhook" : "webhook"
        let doveGUID = trigger == .dove ? configGroups.resolved[chatID] : nil
        let generation = databaseGeneration
        let detail: String? = job ? "job" : requestText.map { _ in "dove" }
        if rawURL.isEmpty {
            return deadLetter(event, error: "webhook_not_configured", attempts: 0, kind: kind, detail: detail)
        }
        guard let url = job ? EndpointURL.httpsOrLoopback(rawURL) : EndpointURL.https(rawURL) else {
            return deadLetter(event, error: "url_not_https", attempts: 0, kind: kind, detail: detail)
        }
        func sharedSenderHandle() -> String? {
            guard !senderIsMe && !config.selfChatIDs.contains(chatID)
                && configGroups.permitsReceive(chatID, guid: event.chatGUID) else { return nil }
            let normalized = SenderHandle.normalize(event.sender)
            if job {
                return normalized.flatMap { JobSenderHandle.isContractValue($0) ? $0 : nil }
            }
            return normalized ?? ""
        }
        func encodePayload() throws -> Data {
            let payload = WebhookPayload(
                v: 1, event: "message", idempotencyKey: event.guid, guid: event.guid,
                chatID: chatID, text: text, createdAt: event.createdAt,
                senderIsMe: senderIsMe, senderName: senderName,
                senderHandle: sharedSenderHandle(),
                trigger: job ? nil : trigger, requestText: requestText
            )
            return try payload.encodeData()
        }
        do { _ = try encodePayload() }
        catch { return deadLetter(event, error: "webhook_encode_failed", attempts: 0, kind: kind, detail: detail) }
        if !event.guid.isEmpty {
            rememberRoute(guid: event.guid, chatID: chatID, addressee: replyAddressee(event, chatID: chatID),
                          trigger: trigger == .dove ? trigger.rawValue : nil,
                          chatGUIDHash: doveGUID.map { SHA256.hex(Data($0.utf8)) })
            if !persist() {
                return .blocked
            }
        }

        let maxAttempts = config.webhookMaxAttempts
        var last = "webhook_transport"
        var attempt = 0
        while attempt < maxAttempts {
            refreshConfig()
            attempt += 1
            if paused {
                return .deferredPaused
            }
            if trigger == .dove, generation != databaseGeneration { return .ignoredDatabaseReset }
            if trigger == .dove ? !isDoveChat(chatID, guid: doveGUID) : !allowsReceive(chatID, guid: event.chatGUID) {
                log.record(level: .info, code: "webhook_chat_disabled", chatID: chatID, guid: event.guid, rowid: event.id,
                           detail: trigger == .dove ? "dove" : nil)
                return finish(event, .ignoredNotAllowed)
            }
            let token: String
            do {
                token = try job ? secrets.jobWebhookSecret() : secrets.webhookSecret()
            } catch let error as SecretReadError {
                let code = (job ? "job_" : "") + secretCode(error)
                if error != .unreadable {
                    return deadLetter(event, error: code, attempts: attempt, kind: kind, detail: detail)
                }
                last = code
                if attempt < maxAttempts, await sleepBackoff(attempt: attempt) == false {
                    return .deferredPaused
                }
                continue
            } catch {
                last = job ? "job_secret_unreadable" : "secret_unreadable"
                if attempt < maxAttempts, await sleepBackoff(attempt: attempt) == false {
                    return .deferredPaused
                }
                continue
            }
            if paused {
                return .deferredPaused
            }
            if trigger == .dove, generation != databaseGeneration { return .ignoredDatabaseReset }
            if trigger == .dove ? !isDoveChat(chatID, guid: doveGUID) : !allowsReceive(chatID, guid: event.chatGUID) {
                log.record(level: .info, code: "webhook_chat_disabled", chatID: chatID, guid: event.guid, rowid: event.id,
                           detail: trigger == .dove ? "dove" : nil)
                return finish(event, .ignoredNotAllowed)
            }
            let body: Data
            do { body = try encodePayload() }
            catch { return deadLetter(event, error: "webhook_encode_failed", attempts: attempt, kind: kind, detail: detail) }
            do {
                if job && !senderIsMe && !config.selfChatIDs.contains(chatID)
                    && configGroups.permitsReceive(chatID, guid: event.chatGUID) && sharedSenderHandle() == nil {
                    log.record(level: .info, code: "job_sender_handle_unusable", chatID: chatID, guid: event.guid, rowid: event.id)
                }
                let response = try await webhook.post(
                    url: url,
                    secret: token,
                    body: body,
                    idempotencyKey: event.guid
                )
                if trigger == .dove, generation != databaseGeneration { return .ignoredDatabaseReset }
                if (200...299).contains(response.statusCode) {
                    lastError = nil
                    log.record(level: .info, code: "webhook_delivered", chatID: chatID, guid: event.guid, rowid: event.id, detail: detail)
                    return finish(event, .delivered)
                }
                last = "webhook_http_\(response.statusCode)"
                if !WebhookRetry.shouldRetry(statusCode: response.statusCode) {
                    return deadLetter(event, error: last, attempts: attempt, kind: kind, detail: detail)
                }
            } catch {
                if trigger == .dove, generation != databaseGeneration { return .ignoredDatabaseReset }
                last = "webhook_transport"
            }
            if attempt < maxAttempts {
                if job {
                    log.record(level: .error, code: last, chatID: chatID, guid: event.guid, rowid: event.id, detail: detail)
                }
                if await sleepBackoff(attempt: attempt) == false {
                    return .deferredPaused
                }
            }
        }
        return deadLetter(event, error: last, attempts: attempt, kind: kind, detail: detail)
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

    private func deadLetter(_ event: WatchEvent, error: String, attempts: Int, kind: String = "webhook", detail: String? = nil) -> IngestResult {
        let entry = DeadLetterEntry(
            ts: ISO8601.string(from: clock.now()),
            kind: kind,
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
        log.record(level: .error, code: error, chatID: event.chatID, guid: event.guid, rowid: event.id, detail: detail)
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
            expiredReplyThisPass = true
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
        let trigger: ReplyTrigger = route.trigger == ReplyTrigger.dove.rawValue ? .dove : .lamp
        if trigger == .lamp && !allowsSend(chatID) {
            log.record(level: .info, code: "reply_chat_disabled", chatID: chatID, guid: nil, rowid: nil)
            markReplyHandled(reply.id)
            persist()
            return
        }
        let body: String
        switch ReplyComposer.split(body: reply.text, marker: config.replyMarker, stripDove: trigger == .dove) {
        case .emptyBody:
            markReplyHandled(reply.id)
            persisted.partialReplies.removeAll { $0.replyID == reply.id }
            log.record(level: .error, code: "reply_empty_body", chatID: chatID, guid: nil, rowid: nil)
            persist()
            return
        case .stillSignal:
            markReplyHandled(reply.id)
            persisted.partialReplies.removeAll { $0.replyID == reply.id }
            lastError = "reply_still_matches_signal"
            log.record(level: .error, code: "reply_still_matches_signal", chatID: chatID, guid: nil, rowid: nil)
            persist()
            return
        case .send(let value):
            let candidate = ReplyComposer.withAddressee(route.addressee, to: value)
            body = Signal.matches(candidate) || ReplyComposer.isReplyMarker(candidate, marker: config.replyMarker)
                || (trigger == .dove && DoveSignal.matches(candidate))
                ? value : candidate
        }

        if let partial = persisted.partialReplies.first(where: { $0.replyID == reply.id }) {
            guard partial.chatID == chatID else {
                markReplyHandled(reply.id)
                persisted.partialReplies.removeAll { $0.replyID == reply.id }
                persist()
                return
            }
        } else if inFlightReplyIDs.contains(where: { otherID in
            otherID != reply.id && inFlightReplyChats[otherID] == chatID
        }) || persisted.partialReplies.contains(where: { $0.chatID == chatID && $0.replyID != reply.id }) {
            chatWaitingReplyIDs.insert(reply.id)
            return
        }

        if paused || stop.isStopped { return }
        await performSend(
            replyID: reply.id,
            chatID: chatID,
            part: persisted.partialReplies.contains(where: { $0.replyID == reply.id }) ? .body : .marker,
            body: body,
            attempts: 1,
            reserved: false,
            pauseReason: .appleEventNotStarted,
            createdAt: created,
            origin: trigger == .dove ? .dove(chatGUIDHash: route.chatGUIDHash) : .lamp
        )
    }

    private func performSend(
        replyID: String,
        chatID: Int64,
        part: SendPart,
        body: String,
        attempts: Int,
        reserved: Bool,
        pauseReason: HoldReason,
        createdAt: Date,
        origin: SendOrigin
    ) async {
        if !reserved {
            guard inFlightReplyIDs.insert(replyID).inserted else { return }
            inFlightReplyChats[replyID] = chatID
        }
        defer {
            inFlightReplyIDs.remove(replyID)
            inFlightReplyChats.removeValue(forKey: replyID)
        }
        refreshConfig()
        if part == .marker {
            await sendMarker(
                replyID: replyID, chatID: chatID, body: body, attempts: attempts,
                pauseReason: pauseReason, createdAt: createdAt, origin: origin
            )
        } else {
            await sendBody(
                replyID: replyID, chatID: chatID, body: body, attempts: attempts,
                pauseReason: pauseReason, createdAt: createdAt, origin: origin
            )
        }
    }

    private func sendMarker(
        replyID: String, chatID: Int64, body: String, attempts: Int, pauseReason: HoldReason,
        createdAt: Date, origin: SendOrigin
    ) async {
        guard sendGuard(replyID: replyID, chatID: chatID, body: body, part: .marker, attempts: attempts, createdAt: createdAt, origin: origin) else { return }
        if paused || stop.isStopped {
            hold(replyID: replyID, chatID: chatID, part: .marker, body: body, reason: pauseReason,
                 attempts: attempts, logIt: false, immediate: true, createdAt: createdAt, origin: origin)
            return
        }
        guard allowsSend(chatID) else { dropDisabled(replyID: replyID, chatID: chatID, detail: "marker"); return }
        if rejectMismatchedChatGuid(replyID: replyID, chatID: chatID) {
            restoreHoldWhenUnchecked(replyID: replyID, chatID: chatID, part: .marker, body: body,
                reason: pauseReason, attempts: attempts, createdAt: createdAt, origin: origin)
            return
        }
        let generation = databaseGeneration
        let locked = await lock.state()
        noteLock(locked)
        guard generation == databaseGeneration else { return }
        refreshConfig()
        guard sendGuard(replyID: replyID, chatID: chatID, body: body, part: .marker, attempts: attempts, createdAt: createdAt, origin: origin) else { return }
        if paused || stop.isStopped {
            hold(replyID: replyID, chatID: chatID, part: .marker, body: body, reason: pauseReason,
                 attempts: attempts, logIt: false, immediate: true, createdAt: createdAt, origin: origin)
            return
        }
        guard allowsSend(chatID) else { dropDisabled(replyID: replyID, chatID: chatID, detail: "marker"); return }
        if rejectMismatchedChatGuid(replyID: replyID, chatID: chatID) {
            restoreHoldWhenUnchecked(replyID: replyID, chatID: chatID, part: .marker, body: body,
                reason: pauseReason, attempts: attempts, createdAt: createdAt, origin: origin)
            return
        }
        if locked == .locked {
            let first = attempts == 1 && !holds.contains { $0.replyID == replyID }
            hold(replyID: replyID, chatID: chatID, part: .marker, body: body, reason: .screenLocked,
                 attempts: attempts, logIt: first, createdAt: createdAt, origin: origin)
            if first { lastError = "screen_locked" }
            return
        }
        if persisted.haltedChatIDs.contains(chatID) || !authorize(chatID: chatID, now: clock.now()) {
            let newlyHalted = !persisted.haltedChatIDs.contains(chatID)
            if newlyHalted {
                persisted.haltedChatIDs.append(chatID)
                persist()
                lastError = "rate_limited"
                sendLog(replyID: replyID, level: .error, code: "rate_limited", chatID: chatID, guid: nil, rowid: nil)
            }
            hold(replyID: replyID, chatID: chatID, part: .marker, body: body, reason: .rateLimited,
                 attempts: attempts, logIt: false, createdAt: createdAt, origin: origin)
            return
        }
        let reservedAt = clock.now()
        countRate(chatID: chatID, at: reservedAt)
        var attempt: MarkerAttempt
        if case .dove = origin {
            attempt = .text(DoveSignal.marker)
        } else {
            switch MarkerImage.check(markerImage.markerImageURL()) {
            case .usable(let path):
                noticeLog.resolve(["marker_image_unavailable"])
                attempt = .image(path: path)
            case .unavailable(let reason):
                if noticeLog.shouldLog("marker_image_unavailable") {
                    sendLog(replyID: replyID, level: .warning, code: "marker_image_unavailable", chatID: chatID,
                               guid: nil, rowid: nil, detail: reason.rawValue)
                }
                attempt = .text(config.replyMarker)
            }
        }

        while true {
            if isOutbound(replyID) || DoveSignal.matches(body) { refreshConfig() }
            let text: String
            if case .text(let marker) = attempt {
                text = marker
            } else {
                text = ""
            }
            recordIntent(replyID: replyID, chatID: chatID, text: text,
                         at: reservedAt, rateCounted: true, part: .marker, markerKind: attempt.kind)
            guard persist() else {
                releaseRate(chatID: chatID, at: reservedAt)
                rollbackIntent(replyID: replyID)
                hold(replyID: replyID, chatID: chatID, part: .marker, body: body,
                     reason: .appleEventNotStarted, attempts: attempts, logIt: false,
                     createdAt: createdAt, origin: origin)
                return
            }
            if paused || stop.isStopped {
                releaseRate(chatID: chatID, at: reservedAt)
                rollbackIntent(replyID: replyID)
                persist()
                hold(replyID: replyID, chatID: chatID, part: .marker, body: body, reason: pauseReason,
                     attempts: attempts, logIt: false, immediate: true, createdAt: createdAt, origin: origin)
                return
            }
            if origin == .lamp && DoveSignal.matches(body) { refreshConfig() }
            if !allowsSend(chatID) {
                releaseRate(chatID: chatID, at: reservedAt)
                rollbackIntent(replyID: replyID)
                dropDisabled(replyID: replyID, chatID: chatID, detail: "marker")
                return
            }
            if rejectMismatchedChatGuid(replyID: replyID, chatID: chatID) {
                releaseRate(chatID: chatID, at: reservedAt)
                rollbackIntent(replyID: replyID)
                persist()
                restoreHoldWhenUnchecked(replyID: replyID, chatID: chatID, part: .marker, body: body,
                    reason: pauseReason, attempts: attempts, createdAt: createdAt, origin: origin)
                return
            }

            if origin != .lamp { refreshConfig() }
            guard sendGuard(replyID: replyID, chatID: chatID, body: body, part: .marker, attempts: attempts, createdAt: createdAt, origin: origin) else {
                releaseRate(chatID: chatID, at: reservedAt)
                rollbackIntent(replyID: replyID)
                persist()
                return
            }
            let result: Result<SendReceipt, SendFailure>
            do {
                switch attempt {
                case .image(let path): result = .success(try await sender.sendFile(chatID: chatID, path: path))
                case .text(let marker): result = .success(try await sender.send(chatID: chatID, text: marker))
                }
            } catch let failure as SendFailure {
                result = .failure(failure)
            } catch {
                result = .failure(.failed)
            }
            if isOutbound(replyID) { refreshConfig() }
            if generation != databaseGeneration {
                if case .success(let receipt) = result { appendCapped(receipt.guid, to: &persisted.sentGUIDs) }
                finishIntent(replyID: replyID)
                markReplyHandled(replyID)
                persist()
                logDroppedForDatabaseReset(detail: "marker")
                return
            }
            if let index = outboundRecordIndex(replyID),
               persisted.outbound.records[index].sourceHash != outboundSourceHash() || (isOutbound(replyID) && !config.outboundEnabled) {
                if case .success(let receipt) = result { appendCapped(receipt.guid, to: &persisted.sentGUIDs) }
                terminateOutbound(replyID, code: "outbound_source_changed")
                return
            }
            switch result {
            case .success(let receipt) where !receipt.guid.isEmpty:
                finishIntent(replyID: replyID)
                appendCapped(receipt.guid, to: &persisted.sentGUIDs)
                let partial = PartialReply(replyID: replyID, chatID: chatID, markerGUID: receipt.guid, at: clock.now())
                addPartialReply(partial)
                guard persist() else {
                    hold(replyID: replyID, chatID: chatID, part: .body, body: body,
                         reason: .appleEventNotStarted, attempts: 1, logIt: false,
                         createdAt: createdAt, origin: origin)
                    return
                }
                let isDoveMarker = text == DoveSignal.marker
                sendLog(replyID: replyID, level: .info, code: "reply_sent", chatID: chatID,
                           guid: isDoveMarker ? nil : receipt.guid, rowid: receipt.id,
                           detail: isDoveMarker ? "dove" : attempt.detail)
                await sendBody(replyID: replyID, chatID: chatID, body: body, attempts: 1,
                               pauseReason: pauseReason, createdAt: createdAt, origin: origin)
                return
            case .success:
                await handleMarkerFailure(replyID: replyID, chatID: chatID, body: body,
                    failure: .uncertain, attempts: attempts, createdAt: createdAt, origin: origin,
                    detail: attempt.detail, rateAt: reservedAt)
                return
            case .failure(.failed) where attempt.kind == .image:
                sendLog(replyID: replyID, level: .warning, code: "marker_image_failed", chatID: chatID,
                           guid: nil, rowid: nil)
                rollbackIntent(replyID: replyID)
                attempt = .text(config.replyMarker)
            case .failure(let failure):
                await handleMarkerFailure(replyID: replyID, chatID: chatID, body: body,
                    failure: failure, attempts: attempts, createdAt: createdAt, origin: origin,
                    detail: attempt.detail, rateAt: reservedAt)
                return
            }
        }
    }

    private func handleMarkerFailure(
        replyID: String, chatID: Int64, body: String, failure: SendFailure, attempts: Int,
        createdAt: Date, origin: SendOrigin, detail: String = "marker", rateAt: Date? = nil
    ) async {
        if isOutbound(replyID) && failure != .notStarted {
            if failure == .failed {
                let at = persisted.pendingSends.first(where: { $0.replyID == replyID })?.at ?? rateAt
                if let at { releaseRate(chatID: chatID, at: at) }
            }
            terminateOutbound(replyID, code: failure == .failed ? "outbound_send_failed" : "outbound_send_uncertain", deadLetter: true)
            return
        }
        let pending = persisted.pendingSends.first { $0.replyID == replyID }
        switch failure {
        case .notStarted:
            if let at = pending?.at ?? rateAt { releaseRate(chatID: chatID, at: at) }
            rollbackIntent(replyID: replyID)
            hold(replyID: replyID, chatID: chatID, part: .marker, body: body,
                 reason: .appleEventNotStarted, attempts: attempts, logIt: attempts == 1,
                 detail: detail,
                 createdAt: createdAt, origin: origin)
            if attempts == 1 { lastError = "apple_event_1712" }
            persist()
        case .failed:
            if let pending { releaseRate(chatID: chatID, at: pending.at) }
            rollbackIntent(replyID: replyID)
            holds.removeAll { $0.replyID == replyID }
            if recordReplyDeadLetter(replyID: replyID, chatID: chatID, error: "send_failed") {
                finishIntent(replyID: replyID)
                markReplyHandled(replyID)
                persist()
                lastError = "send_failed"
            } else {
                hold(replyID: replyID, chatID: chatID, part: .marker, body: body,
                     reason: .appleEventNotStarted, attempts: attempts, logIt: false,
                     createdAt: createdAt, origin: origin)
                persist()
            }
            sendLog(replyID: replyID, level: .error, code: "send_failed", chatID: chatID, guid: nil, rowid: nil, detail: detail)
        case .uncertain:
            holds.removeAll { $0.replyID == replyID }
            markReplyHandled(replyID)
            let wrote = recordReplyDeadLetter(replyID: replyID, chatID: chatID, error: "send_uncertain")
            if wrote { finishIntent(replyID: replyID) }
            else if let index = persisted.pendingSends.firstIndex(where: { $0.replyID == replyID }) {
                persisted.pendingSends[index].rateCounted = true
            }
            if wrote { lastError = "send_uncertain" }
            sendLog(replyID: replyID, level: .error, code: "send_uncertain", chatID: chatID, guid: nil, rowid: nil, detail: detail)
            persist()
        }
    }

    private func sendBody(
        replyID: String, chatID: Int64, body: String, attempts: Int, pauseReason: HoldReason,
        createdAt: Date, origin: SendOrigin
    ) async {
        if origin != .lamp || DoveSignal.matches(body) { refreshConfig() }
        if !isOutbound(replyID), !persisted.partialReplies.contains(where: { $0.replyID == replyID }) { return }
        guard sendGuard(replyID: replyID, chatID: chatID, body: body, part: .body, attempts: attempts, createdAt: createdAt, origin: origin) else { return }
        if paused || stop.isStopped {
            hold(replyID: replyID, chatID: chatID, part: .body, body: body, reason: pauseReason,
                 attempts: attempts, logIt: false, immediate: true, createdAt: createdAt, origin: origin)
            return
        }
        guard allowsSend(chatID) else { dropDisabled(replyID: replyID, chatID: chatID, detail: "body"); return }
        if rejectMismatchedChatGuid(replyID: replyID, chatID: chatID) {
            restoreHoldWhenUnchecked(replyID: replyID, chatID: chatID, part: .body, body: body,
                reason: pauseReason, attempts: attempts, createdAt: createdAt, origin: origin)
            return
        }
        let generation = databaseGeneration
        let locked = await lock.state()
        noteLock(locked)
        guard generation == databaseGeneration else { return }
        refreshConfig()
        guard sendGuard(replyID: replyID, chatID: chatID, body: body, part: .body, attempts: attempts, createdAt: createdAt, origin: origin) else { return }
        if paused || stop.isStopped {
            hold(replyID: replyID, chatID: chatID, part: .body, body: body, reason: pauseReason,
                 attempts: attempts, logIt: false, immediate: true, createdAt: createdAt, origin: origin)
            return
        }
        guard allowsSend(chatID) else { dropDisabled(replyID: replyID, chatID: chatID, detail: "body"); return }
        if rejectMismatchedChatGuid(replyID: replyID, chatID: chatID) {
            restoreHoldWhenUnchecked(replyID: replyID, chatID: chatID, part: .body, body: body,
                reason: pauseReason, attempts: attempts, createdAt: createdAt, origin: origin)
            return
        }
        if locked == .locked {
            let first = attempts == 1 && !holds.contains { $0.replyID == replyID }
            hold(replyID: replyID, chatID: chatID, part: .body, body: body, reason: .screenLocked,
                 attempts: attempts, logIt: first, createdAt: createdAt, origin: origin)
            if first { lastError = "screen_locked" }
            return
        }
        if bodyResendSavePending.contains(replyID) {
            guard persist() else {
                hold(replyID: replyID, chatID: chatID, part: .body, body: body,
                     reason: .appleEventNotStarted, attempts: attempts, logIt: false,
                     createdAt: createdAt, origin: origin)
                return
            }
            bodyResendSavePending.remove(replyID)
        }
        let sendingResend = (persisted.partialReplies.first(where: { $0.replyID == replyID })?.bodyResends ?? 0) > 0
        let reservedAt = clock.now()
        recordIntent(replyID: replyID, chatID: chatID, text: body, at: reservedAt, rateCounted: true, part: .body)
        guard persist() else {
            rollbackIntent(replyID: replyID)
            hold(replyID: replyID, chatID: chatID, part: .body, body: body,
                 reason: .appleEventNotStarted, attempts: attempts, logIt: false,
                 createdAt: createdAt, origin: origin)
            return
        }
        guard sendGuard(replyID: replyID, chatID: chatID, body: body, part: .body, attempts: attempts, createdAt: createdAt, origin: origin) else { return }
        if paused || stop.isStopped {
            rollbackIntent(replyID: replyID)
            persist()
            hold(replyID: replyID, chatID: chatID, part: .body, body: body, reason: pauseReason,
                 attempts: attempts, logIt: false, immediate: true, createdAt: createdAt, origin: origin)
            return
        }
        if origin == .lamp && DoveSignal.matches(body) { refreshConfig() }
        if !allowsSend(chatID) {
            rollbackIntent(replyID: replyID)
            dropDisabled(replyID: replyID, chatID: chatID, detail: "body")
            return
        }
        if rejectMismatchedChatGuid(replyID: replyID, chatID: chatID) {
            rollbackIntent(replyID: replyID)
            persist()
            restoreHoldWhenUnchecked(replyID: replyID, chatID: chatID, part: .body, body: body,
                reason: pauseReason, attempts: attempts, createdAt: createdAt, origin: origin)
            return
        }
        if origin != .lamp { refreshConfig() }
        guard sendGuard(replyID: replyID, chatID: chatID, body: body, part: .body, attempts: attempts, createdAt: createdAt, origin: origin) else {
            rollbackIntent(replyID: replyID)
            persist()
            return
        }
        let sendResult: Result<SendReceipt, SendFailure>
        do { sendResult = .success(try await sender.send(chatID: chatID, text: body)) }
        catch let failure as SendFailure { sendResult = .failure(failure) }
        catch { sendResult = .failure(.failed) }
        if isOutbound(replyID) { refreshConfig() }
        if generation != databaseGeneration {
            if case .success(let receipt) = sendResult { appendCapped(receipt.guid, to: &persisted.sentGUIDs) }
            finishIntent(replyID: replyID)
            markReplyHandled(replyID)
            persist()
            logDroppedForDatabaseReset(detail: sendingResend ? "resend" : "body")
            return
        }
        if let index = outboundRecordIndex(replyID),
           persisted.outbound.records[index].sourceHash != outboundSourceHash() || (isOutbound(replyID) && !config.outboundEnabled) {
            if case .success(let receipt) = sendResult { appendCapped(receipt.guid, to: &persisted.sentGUIDs) }
            terminateOutbound(replyID, code: "outbound_source_changed")
            return
        }
        switch sendResult {
        case .success(let receipt) where !receipt.guid.isEmpty:
            finishIntent(replyID: replyID)
            appendCapped(receipt.guid, to: &persisted.sentGUIDs)
            persisted.partialReplies.removeAll { $0.replyID == replyID }
            markReplyHandled(replyID)
            holds.removeAll { $0.replyID == replyID }
            lastError = nil
            let loggedGUID: String? = if case .dove = origin { nil } else { receipt.guid }
            sendLog(replyID: replyID, level: .info, code: "reply_sent", chatID: chatID, guid: loggedGUID,
                       rowid: receipt.id, detail: sendingResend ? "resend" : "body")
            persist()
        case .success:
            await handleBodyFailure(replyID: replyID, chatID: chatID, body: body, failure: .uncertain,
                attempts: attempts, sendingResend: sendingResend, pauseReason: pauseReason,
                createdAt: createdAt, origin: origin)
        case .failure(.notStarted):
            rollbackIntent(replyID: replyID)
            hold(replyID: replyID, chatID: chatID, part: .body, body: body,
                 reason: .appleEventNotStarted, attempts: attempts, logIt: attempts == 1,
                 detail: "body",
                 createdAt: createdAt, origin: origin)
            if attempts == 1 { lastError = "apple_event_1712" }
            persist()
        case .failure(let failure):
            await handleBodyFailure(replyID: replyID, chatID: chatID, body: body, failure: failure,
                attempts: attempts, sendingResend: sendingResend, pauseReason: pauseReason,
                createdAt: createdAt, origin: origin)
        }
    }

    private func handleBodyFailure(
        replyID: String, chatID: Int64, body: String, failure: SendFailure, attempts: Int,
        sendingResend: Bool, pauseReason: HoldReason, createdAt: Date, origin: SendOrigin
    ) async {
        if isOutbound(replyID) {
            terminateOutbound(replyID,
                code: failure == .failed ? "outbound_body_send_failed" : "outbound_body_send_uncertain",
                deadLetter: true)
            return
        }
        guard let partialIndex = persisted.partialReplies.firstIndex(where: { $0.replyID == replyID }) else { return }
        let partial = persisted.partialReplies[partialIndex]
        let code = failure == .failed ? "send_failed" : "send_uncertain"
        switch BodyResendPolicy.decide(resendsUsed: partial.bodyResends) {
        case .resend:
            if failure == .failed { rollbackIntent(replyID: replyID) }
            else { finishIntent(replyID: replyID) }
            persisted.partialReplies[partialIndex].bodyResends += 1
            bodyResendSavePending.insert(replyID)
            lastError = code
            sendLog(replyID: replyID, level: .error, code: code, chatID: chatID, guid: nil, rowid: nil, detail: "body")
            guard persist() else {
                hold(replyID: replyID, chatID: chatID, part: .body, body: body,
                     reason: .appleEventNotStarted, attempts: attempts, logIt: false,
                     createdAt: createdAt, origin: origin)
                return
            }
            bodyResendSavePending.remove(replyID)
            await sendBody(replyID: replyID, chatID: chatID, body: body, attempts: attempts + 1,
                           pauseReason: pauseReason, createdAt: createdAt, origin: origin)
        case .deadLetter:
            persisted.partialReplies.removeAll { $0.replyID == replyID }
            holds.removeAll { $0.replyID == replyID }
            markReplyHandled(replyID)
            let error = failure == .failed ? "body_send_failed" : "body_send_uncertain"
            if recordReplyDeadLetter(replyID: replyID, chatID: chatID, error: error, attempts: 2) {
                finishIntent(replyID: replyID)
                lastError = code
            } else if let index = persisted.pendingSends.firstIndex(where: { $0.replyID == replyID }) {
                persisted.pendingSends[index].rateCounted = true
            }
            sendLog(replyID: replyID, level: .error, code: code, chatID: chatID, guid: nil, rowid: nil, detail: "resend")
            persist()
        }
    }

    /// そのトークの guid を一覧で確かめられたときだけ送る。
    /// 一覧が空、その id が無い、取得に失敗、guid が違う、のいずれも送らない。
    /// 理由はメニューとログに出す。番号、メール、識別子は出さない。
    private func rejectMismatchedChatGuid(replyID: String, chatID: Int64, doveGUID: String? = nil) -> Bool {
        if isOutbound(replyID) { return !outboundAuthorizationMatches(replyID: replyID, chatID: chatID) }
        let current = directoryGUIDs[chatID] ?? ""
        var expected = configGroups.expectedGUIDs(for: chatID)
        if let doveGUID { expected.append(doveGUID) }
        if let entry = allowlist.entries.first(where: { $0.id == chatID }) {
            expected.append(entry.guid)
        }
        let allowed = expected.first(where: { $0 != current }) ?? expected.first ?? ""
        if directoryChecked && !current.isEmpty && !allowed.isEmpty && current == allowed {
            return false
        }
        if !directoryChecked {
            let code = parseProblem == .allRows ? "chats_parse_failed" : "chats_failed"
            logListCode(code)
            return true
        }
        let code = holdReasonCode(current: current, allowed: allowed)
        if !current.isEmpty && !allowed.isEmpty && current != allowed {
            holds.removeAll { $0.replyID == replyID }
            markReplyHandled(replyID)
            guidMismatchOutstanding = true
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
        notedHoldThisPass = true
        if code == "reply_chat_guid_mismatch" {
            guidMismatchOutstanding = true
            logListCode(code)
            return
        }
        guard code == "reply_held_empty_list" || code == "reply_held_not_in_list" else { return }
        if transientHold == code { return }
        if let previous = transientHold {
            noticeLog.resolve([previous])
        }
        transientHold = code
        logListCode(code)
    }

    private func dropDisabled(replyID: String, chatID: Int64, detail: String? = nil, code: String = "reply_chat_disabled") {
        if isOutbound(replyID) { terminateOutbound(replyID, code: "outbound_chat_disabled"); return }
        holds.removeAll { $0.replyID == replyID }
        persisted.partialReplies.removeAll { $0.replyID == replyID }
        bodyResendSavePending.remove(replyID)
        markReplyHandled(replyID)
        lastError = code
        log.record(level: code == "reply_still_matches_dove" ? .error : .info, code: code,
                   chatID: chatID, guid: nil, rowid: nil, detail: detail)
        persist()
    }

    /// 再送の途中で一覧が未確認に戻ったら、取り出していた返事を保留へ戻す。
    private func restoreHoldWhenUnchecked(
        replyID: String,
        chatID: Int64,
        part: SendPart,
        body: String,
        reason: HoldReason,
        attempts: Int,
        createdAt: Date,
        origin: SendOrigin
    ) {
        guard !directoryChecked else { return }
        hold(
            replyID: replyID,
            chatID: chatID,
            part: part,
            body: body,
            reason: reason,
            attempts: attempts,
            logIt: false,
            immediate: true,
            createdAt: createdAt,
            origin: origin
        )
    }

    private func hold(
        replyID: String,
        chatID: Int64,
        part: SendPart,
        body: String,
        reason: HoldReason,
        attempts: Int,
        logIt: Bool,
        immediate: Bool = false,
        detail: String? = nil,
        createdAt: Date,
        origin: SendOrigin
    ) {
        holds.removeAll { $0.replyID == replyID }
        let delay = immediate ? 0 : config.holdRetryIntervalSeconds
        holds.append(
            HeldSend(
                replyID: replyID,
                chatID: chatID,
                part: part,
                body: body,
                reason: reason,
                attempts: attempts,
                nextAttemptAt: clock.now().addingTimeInterval(delay),
                createdAt: createdAt,
                origin: origin
            )
        )
        if logIt {
            sendLog(replyID: replyID, level: .error, code: reason.rawValue, chatID: chatID, guid: nil, rowid: nil,
                       detail: detail ?? part.rawValue)
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

    private func recordIntent(
        replyID: String, chatID: Int64, text: String, at: Date, rateCounted: Bool,
        part: SendPart, markerKind: MarkerKind? = nil
    ) {
        if let index = outboundRecordIndex(replyID) {
            persisted.outbound.records[index].stage = part == .marker ? .markerInFlight : .bodyInFlight
        } else {
            let hash = markerKind == .image ? "" : SHA256.hex(Data(TextNormalizer.nfc(text).utf8))
            persisted.pendingSends.removeAll { $0.replyID == replyID }
            persisted.pendingSends.append(
                PendingSend(replyID: replyID, chatID: chatID, hash: hash, at: at,
                            rateCounted: rateCounted, part: part, markerKind: markerKind)
            )
            cap(&persisted.pendingSends)
        }
        let hash = markerKind == .image ? "" : SHA256.hex(Data(TextNormalizer.nfc(text).utf8))
        if !hash.isEmpty {
            persisted.fingerprints.append(SentFingerprint(hash: hash, sentAt: at))
            if isOutbound(replyID) { outboundIntentFingerprints[replyID] = (hash, at) }
        }
        pruneFingerprints(now: at)
    }

    private func rollbackIntent(replyID: String) {
        if let index = outboundRecordIndex(replyID), persisted.outbound.records[index].stage != .terminal {
            persisted.outbound.records[index].stage = persisted.outbound.records[index].stage == .bodyInFlight ? .bodyReady : .reserved
        }
        if let outboundFingerprint = outboundIntentFingerprints.removeValue(forKey: replyID) {
            if let index = persisted.fingerprints.lastIndex(where: { $0.hash == outboundFingerprint.0 && $0.sentAt == outboundFingerprint.1 }) {
                persisted.fingerprints.remove(at: index)
            }
        } else if let pending = persisted.pendingSends.first(where: { $0.replyID == replyID }) {
            persisted.pendingSends.removeAll { $0.replyID == replyID }
            if let index = persisted.fingerprints.lastIndex(where: { $0.hash == pending.hash && $0.sentAt == pending.at }) {
                persisted.fingerprints.remove(at: index)
            }
        }
    }

    private func finishIntent(replyID: String) {
        persisted.pendingSends.removeAll { $0.replyID == replyID }
        outboundIntentFingerprints.removeValue(forKey: replyID)
    }

    private func addPartialReply(_ partial: PartialReply) {
        if let index = outboundRecordIndex(partial.replyID) {
            persisted.outbound.records[index].stage = .bodyReady
            return
        }
        persisted.partialReplies.removeAll { $0.replyID == partial.replyID }
        persisted.partialReplies.append(partial)
        while persisted.partialReplies.count > 5000 {
            let dropped = persisted.partialReplies.removeFirst()
            markReplyHandled(dropped.replyID)
            sendLog(replyID: dropped.replyID, level: .info, code: "reply_partial_dropped", chatID: dropped.chatID,
                       guid: nil, rowid: nil, detail: "body")
        }
    }

    private func prunePartialReplies() {
        let cutoff = clock.now().addingTimeInterval(-config.routeTTLSeconds)
        let outboundIDs = Set(persisted.outbound.records.map(\.id))
        let expired = persisted.partialReplies.filter { $0.at < cutoff && !outboundIDs.contains($0.replyID) }
        guard !expired.isEmpty else { return }
        persisted.partialReplies.removeAll { $0.at < cutoff && !outboundIDs.contains($0.replyID) }
        for partial in expired {
            markReplyHandled(partial.replyID)
            log.record(level: .info, code: "reply_partial_dropped", chatID: partial.chatID,
                       guid: nil, rowid: nil, detail: "body")
        }
        persist()
    }

    private func logDroppedForDatabaseReset(detail: String) {
        log.record(level: .info, code: "reply_dropped_db_reset", chatID: nil, guid: nil,
                   rowid: nil, detail: detail)
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
            if item.part == .body,
               let partialIndex = state.partialReplies.firstIndex(where: { $0.replyID == item.replyID }),
               BodyResendPolicy.decide(resendsUsed: state.partialReplies[partialIndex].bodyResends) == .resend {
                state.pendingSends.removeAll { $0.replyID == item.replyID }
                state.partialReplies[partialIndex].bodyResends += 1
                if !item.hash.isEmpty,
                   !state.fingerprints.contains(where: { $0.hash == item.hash && $0.sentAt == item.at }) {
                    state.fingerprints.append(SentFingerprint(hash: item.hash, sentAt: item.at))
                }
                log.record(level: .error, code: "send_interrupted", chatID: item.chatID,
                           guid: nil, rowid: nil, detail: "body")
                continue
            }
            let entry = DeadLetterEntry(
                ts: ISO8601.string(from: now),
                kind: "reply",
                chatID: item.chatID,
                guid: nil,
                rowid: nil,
                attempts: 1,
                error: item.part == .body ? "body_send_interrupted" : "send_interrupted"
            )
            var wrote = false
            do {
                try store.appendDeadLetter(entry)
                wrote = true
            } catch {
                log.record(level: .error, code: "deadletter_write_failed", chatID: item.chatID, guid: nil, rowid: nil)
            }
            if !item.hash.isEmpty,
               !state.fingerprints.contains(where: { $0.hash == item.hash && $0.sentAt == item.at }) {
                state.fingerprints.append(SentFingerprint(hash: item.hash, sentAt: item.at))
            }
            if !item.rateCounted {
                state.rateEvents.append(RateEvent(chatID: item.chatID, at: item.at))
            }
            if !item.replyID.isEmpty, !state.handledReplyIDs.contains(item.replyID) {
                state.handledReplyIDs.append(item.replyID)
            }
            state.partialReplies.removeAll { $0.replyID == item.replyID }
            if wrote {
                log.record(level: .error,
                           code: item.part == .body ? "body_send_interrupted" : "send_interrupted",
                           chatID: item.chatID, guid: nil, rowid: nil,
                           detail: item.part == .body ? "body" : nil)
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

    private func recordReplyDeadLetter(replyID: String, chatID: Int64, error: String, attempts: Int = 1) -> Bool {
        if isOutbound(replyID) {
            terminateOutbound(replyID, code: "outbound_" + error, deadLetter: true)
            return true
        }
        let entry = DeadLetterEntry(
            ts: ISO8601.string(from: clock.now()),
            kind: "reply",
            chatID: chatID,
            guid: nil,
            rowid: nil,
            attempts: attempts,
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
        if let index = outboundRecordIndex(id) {
            if persisted.outbound.records[index].stage != .terminal {
                persisted.outbound.records[index].stage = .terminal
                persisted.outbound.records[index].terminalAt = clock.now()
                persisted.outbound.records[index].terminalCode = "outbound_body_sent"
            }
            persisted.partialReplies.removeAll { $0.replyID == id }
            persisted.pendingSends.removeAll { $0.replyID == id }
            return
        }
        persisted.partialReplies.removeAll { $0.replyID == id }
        HandledReplyIDs.insert(
            id,
            into: &persisted.handledReplyIDs,
            protecting: NotionCursor.ids(in: persisted.replyCursor)
        )
    }

    package func retryOutboundDeadLetters() {
        guard !outboundPersistenceBlocked else { return }
        for index in persisted.outbound.records.indices where persisted.outbound.records[index].deadLetterPending {
            let record = persisted.outbound.records[index]
            do {
                try stateStore.appendDeadLetter(DeadLetterEntry(ts: ISO8601.string(from: clock.now()), kind: "outbound",
                    chatID: nil, guid: nil, rowid: nil, attempts: 1,
                    error: record.terminalCode ?? "outbound_send_interrupted"))
            } catch {
                outboundLog("outbound_deadletter_write_failed")
                continue
            }
            persisted.outbound.records[index].deadLetterPending = false
            if !persist() {
                persisted.outbound.records[index].deadLetterPending = true
                outboundPersistenceBlocked = true
                outboundLog("outbound_state_save_failed")
                return
            }
        }
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

    private func allowsReceive(_ id: Int64, guid: String?) -> Bool {
        allowlist.contains(id) || configGroups.permitsReceive(id, guid: guid)
    }

    private func allowsSend(_ id: Int64) -> Bool {
        allowlist.contains(id) || configGroups.permitsSend(id)
    }

    private func isDoveChat(_ id: Int64, guid: String? = nil) -> Bool {
        guard directoryChecked, let expected = configGroups.resolved[id],
              config.doveChatGUIDs.contains(expected) else { return false }
        return configGroups.permitsReceive(id, guid: guid)
    }

    private func noteConfigGroups() {
        let unmatched = Set(config.doveChatGUIDs).subtracting(config.groupChatGUIDs).count
        let doveCode = "dove_chat_not_in_groups"
        if unmatched == 0 { noticeLog.resolve([doveCode]) }
        else if noticeLog.shouldLog(doveCode) {
            log.record(level: .warning, code: doveCode, chatID: nil, guid: nil, rowid: nil, detail: String(unmatched))
        }
        for (code, count) in [("group_chat_not_found", configGroups.notFound), ("group_chat_not_group", configGroups.notGroup)] {
            if count == 0 { noticeLog.resolve([code]) }
            else if noticeLog.shouldLog(code) {
                log.record(level: .error, code: code, chatID: nil, guid: nil, rowid: nil, detail: String(count))
            }
        }
    }

    private func refreshConfig(forPausedDisplay: Bool = false) {
        do {
            config = try configProvider.load().sanitized()
            noticeLog.resolve(["config_unreadable"])
            configGroups.refresh(guids: config.groupChatGUIDs)
            noteConfigGroups()
            if config.replyMarkerInvalid {
                if noticeLog.shouldLog("reply_marker_invalid") {
                    log.record(level: .warning, code: "reply_marker_invalid", chatID: nil, guid: nil, rowid: nil)
                }
            } else {
                noticeLog.resolve(["reply_marker_invalid"])
            }
        } catch {
            if forPausedDisplay {
                if noticeLog.shouldLog("config_unreadable") {
                    log.record(level: .error, code: "config_unreadable", chatID: nil, guid: nil, rowid: nil)
                }
            } else {
                lastError = "config_unreadable"
                log.record(level: .error, code: "config_unreadable", chatID: nil, guid: nil, rowid: nil)
            }
        }
    }

    private func rememberRoute(guid: String, chatID: Int64, addressee: String? = nil, trigger: String? = nil, chatGUIDHash: String? = nil) {
        let now = clock.now()
        persisted.routes.removeAll {
            $0.guid == guid || now.timeIntervalSince($0.at) > config.routeTTLSeconds
        }
        persisted.routes.append(MessageRoute(guid: guid, chatID: chatID, at: now, addressee: addressee, trigger: trigger,
                                             chatGUIDHash: chatGUIDHash))
        if persisted.routes.count > 5000 {
            persisted.routes.removeFirst(persisted.routes.count - 5000)
        }
    }

    private func replyAddressee(_ event: WatchEvent, chatID: Int64) -> String? {
        guard !event.isFromMe,
              echoParticipants(for: event).isGroup,
              !config.selfChatIDs.contains(chatID) else { return nil }
        return config.replyAddressee(matching: event.sender)
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
        databaseGeneration &+= 1
        for index in persisted.outbound.records.indices where persisted.outbound.records[index].stage != .terminal {
            persisted.outbound.records[index].stage = .terminal
            persisted.outbound.records[index].terminalCode = "outbound_db_reset"
            persisted.outbound.records[index].terminalAt = clock.now()
        }
        configGroups.resetVerification()
        persisted.knownChats = [identity]
        persisted.cursorRowID = 0
        persisted.routes = []
        persisted.pendingSends = []
        persisted.partialReplies = []
        chatWaitingReplyIDs.removeAll()
        bodyResendSavePending.removeAll()
        holds.removeAll()
        allowlist = .empty
        do {
            try allowlistStore.save(allowlist)
        } catch {
            log.record(level: .error, code: "allowlist_save_failed", chatID: identity.id, guid: nil, rowid: nil)
        }
        if !persist() { outboundPersistenceBlocked = true }
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

extension GenieEngine {
    package func pollOutbound() async -> ReplyPollOutcome {
        retryOutboundDeadLetters()
        if stop.isStopped { return .skippedStopped }
        guard directoryChecked else { return .skippedUnchecked }
        if paused { return .skippedPaused }
        refreshConfig()
        let sourceHash = outboundSourceHash()
        synchronizeOutboundSource(sourceHash)
        guard config.outboundEnabled else { return .notConfigured }
        guard !sourceHash.isEmpty else { outboundLog("outbound_source_invalid"); return .notConfigured }
        if !config.outboundSourceConflict { noticeLog.resolve(["outbound_source_conflict"]) }
        if !config.outboundTargetCollision { noticeLog.resolve(["outbound_target_collision"]) }
        guard !outboundFetching else { return .fetchFailed }
        if outboundPersistenceBlocked {
            guard persist() else { outboundLog("outbound_state_save_failed"); return .fetchFailed }
            outboundPersistenceBlocked = false
        }
        retryOutboundDeadLetters()
        outboundFetching = true
        defer { outboundFetching = false }
        if persisted.outboundNotionCursor == nil {
            let start = NotionCursor.freshStart(now: clock.now())
            persisted.outboundNotionCursor = NotionCursor(createdAt: start, seen: [], notBefore: start).encoded()
        }
        guard persist() else {
            outboundPersistenceBlocked = true
            outboundLog("outbound_state_save_failed")
            return .fetchFailed
        }
        let expired = persisted.outbound.records.filter { $0.stage != .terminal && clock.now() >= $0.expiresAt }.map(\.id)
        for id in expired { terminateOutbound(id, code: "outbound_expired") }
        let generation = databaseGeneration
        let prepared = outboundSource.prepared(for: config)
        let originalCursor = persisted.outboundNotionCursor
        let terminalPages = Set(persisted.outbound.records.filter { $0.stage == .terminal }.flatMap(\.pageHashes))
        let activePages = Set(persisted.outbound.records.filter { $0.stage != .terminal }.flatMap(\.pageHashes))
        do {
            let page = try await prepared.fetch(cursor: originalCursor, skipping: terminalPages, holding: activePages)
            if stop.isStopped { return .skippedStopped }
            refreshConfig()
            guard generation == databaseGeneration, sourceHash == outboundSourceHash(), config.outboundEnabled else {
                synchronizeOutboundSource(outboundSourceHash())
                return .fetched
            }
            noticeLog.resolve(["outbound_fetch_failed", "outbound_token_missing", "outbound_token_mode", "outbound_token_empty", "outbound_token_unreadable"])
            let returnedPageHashes = Set(page.entries.map { OutboundHash.digest(kind: "page", values: [$0.pageID]) })
            for record in persisted.outbound.records where record.stage != .terminal
                && record.pageHashes.allSatisfy({ !returnedPageHashes.contains($0) }) {
                outboundLog("outbound_held_body_unavailable")
            }
            for entry in page.entries {
                if stop.isStopped { return .skippedStopped }
                await deliverOutbound(entry, sourceHash: sourceHash)
                if outboundPersistenceBlocked {
                    outboundLog("outbound_state_save_failed")
                    return .fetchFailed
                }
                refreshConfig()
                guard generation == databaseGeneration, sourceHash == outboundSourceHash(), config.outboundEnabled else {
                    synchronizeOutboundSource(outboundSourceHash())
                    return .fetched
                }
            }
            let active = page.entries.filter { entry in
                let pageHash = OutboundHash.digest(kind: "page", values: [entry.pageID])
                return !persisted.outbound.records.contains { $0.pageHashes.contains(pageHash) && $0.stage == .terminal }
            }
            let previous = persisted.outboundNotionCursor
            var next = OutboundCursor.reconcile(proposed: page.nextCursor, unhandled: active) ?? previous
            let unfinished = persisted.outbound.records.filter { $0.stage != .terminal }
            if var cursor = NotionCursor.decode(next), let oldest = unfinished.map(\.createdAt).min() {
                let aliases = Set(unfinished.flatMap(\.pageHashes))
                cursor.seen.removeAll { aliases.contains($0.id) }
                let at = ISO8601.string(from: oldest)
                if cursor.createdAt > at { cursor.createdAt = at }
                cursor.prune()
                next = cursor.encoded()
            }
            persisted.outboundNotionCursor = next
            if !persist() {
                persisted.outboundNotionCursor = previous
                outboundPersistenceBlocked = true
                outboundLog("outbound_state_save_failed")
                return .fetchFailed
            }
            outboundPollWanted = false
            return .fetched
        } catch {
            let code: String
            if case ReplyFetchError.notionToken(let token) = error {
                switch token {
                case .missing: code = "outbound_token_missing"
                case .insecureMode: code = "outbound_token_mode"
                case .empty: code = "outbound_token_empty"
                case .unreadable: code = "outbound_token_unreadable"
                }
            } else { code = "outbound_fetch_failed" }
            outboundLog(code)
            outboundPollWanted = false
            return .fetchFailed
        }
    }

    package func pollOutboundIfDue() async {
        if outboundPollWanted || outboundNextFetchAt == nil || clock.now() >= outboundNextFetchAt! {
            let result = await pollOutbound()
            switch result {
            case .fetched, .fetchFailed, .notConfigured:
                outboundNextFetchAt = clock.now().addingTimeInterval(config.replyPollIntervalSeconds)
            default: break
            }
        }
    }

    private func outboundSourceHash() -> String {
        guard let canonical = NotionDataSourceID.canonical(config.outboundNotionDataSourceID) else { return "" }
        return OutboundHash.digest(kind: "source", values: [canonical])
    }

    private func synchronizeOutboundSource(_ hash: String) {
        if config.outboundSourceConflict { outboundLog("outbound_source_conflict") }
        if config.outboundTargetCollision { outboundLog("outbound_target_collision") }
        guard hash != persisted.outbound.sourceHash || !config.outboundEnabled else { return }
        for index in persisted.outbound.records.indices where persisted.outbound.records[index].stage != .terminal {
            let id = persisted.outbound.records[index].id
            persisted.outbound.records[index].stage = .terminal
            persisted.outbound.records[index].terminalCode = "outbound_source_changed"
            persisted.outbound.records[index].terminalAt = clock.now()
            holds.removeAll { $0.replyID == id }
            persisted.partialReplies.removeAll { $0.replyID == id }
            persisted.pendingSends.removeAll { $0.replyID == id }
            outboundParticipantEvidence.removeValue(forKey: id)
        }
        persisted.outbound.sourceHash = hash
        persisted.outboundNotionCursor = nil
        if !persist() { outboundPersistenceBlocked = true }
    }

    private func outboundRecordIndex(_ id: String) -> Int? {
        persisted.outbound.records.firstIndex { $0.id == id }
    }

    private func isOutbound(_ id: String) -> Bool { outboundRecordIndex(id) != nil }

    private func deliverOutbound(_ entry: FetchedOutbound, sourceHash: String) async {
        let pageHash = OutboundHash.digest(kind: "page", values: [entry.pageID])
        let keyHash = entry.idempotencyKey.map { OutboundHash.digest(kind: "key", values: [$0]) }
        let raw = TextNormalizer.nfc(entry.text ?? "")
        let validated = outboundBody(raw)
        let rawDove = DoveSignal.matches(raw)
        let body = validated.body ?? raw
        let signature = OutboundHash.digest(kind: "signature", values: [entry.target?.rawValue ?? "", body])
        if let index = persisted.outbound.records.firstIndex(where: { $0.pageHashes.contains(pageHash) }) {
            let record = persisted.outbound.records[index]
            guard record.pageHashes.first == pageHash else { return }
            guard record.stage != .terminal else { return }
            guard record.signature == signature, record.keyHash == keyHash else {
                terminateOutbound(record.id, code: "outbound_idempotency_conflict")
                return
            }
            await resumeOutbound(record.id, body: body, rawDove: rawDove)
            return
        }
        if let keyHash, let index = persisted.outbound.records.firstIndex(where: { $0.keyHash == keyHash }) {
            guard persisted.outbound.count < OutboundLedger.capacity else { outboundLog("outbound_ledger_full"); return }
            persisted.outbound.records[index].pageHashes.append(pageHash)
            let sameSignature = persisted.outbound.records[index].signature == signature
            guard persist() else {
                persisted.outbound.records[index].pageHashes.removeAll { $0 == pageHash }
                outboundPersistenceBlocked = true
                outboundLog("outbound_state_save_failed")
                return
            }
            outboundLog(sameSignature ? "outbound_duplicate_key" : "outbound_idempotency_conflict")
            return
        }
        guard persisted.outbound.count < OutboundLedger.capacity else { outboundLog("outbound_ledger_full"); return }
        guard let created = ISO8601.date(from: entry.createdAt) else {
            outboundLog("outbound_bad_entry")
            return
        }
        let targetGUID = entry.target.flatMap { config.outboundTargets[$0.rawValue] } ?? ""
        let destination = OutboundHash.digest(kind: "destination", values: [targetGUID])
        let bodyHash = validated.body.map { OutboundHash.digest(kind: "body", values: [$0]) } ?? ""
        var rejection = entry.invalidCode ?? validated.error
        if entry.target == nil { rejection = "outbound_unknown_target" }
        if entry.idempotencyKey == nil || created.timeIntervalSince(clock.now()) > 60 {
            rejection = "outbound_bad_entry"
        }
        if rejection == nil, entry.target == .family, rawDove || DoveSignal.matches(body),
           directoryChecked, configGroups.resolved.values.contains(targetGUID), config.doveChatGUIDs.contains(targetGUID) {
            rejection = "outbound_dove_body"
        }
        let duplicate = validated.body != nil && rejection == nil && persisted.outbound.records.contains { record in
            record.terminalCode != "outbound_duplicate_body" &&
            record.destinationHash == destination && record.bodyHash == bodyHash &&
            (record.stage != .terminal || (record.terminalAt.map { clock.now() < $0.addingTimeInterval(OutboundLimits.duplicateBodySeconds) } ?? false))
        }
        if duplicate { rejection = "outbound_duplicate_body" }
        let id = "outbound:" + OutboundHash.digest(kind: "delivery", values: [sourceHash, pageHash])
        var record = OutboundRecord(id: id, sourceHash: sourceHash, pageHashes: [pageHash],
            keyHash: keyHash, signature: signature, target: entry.target,
            destinationHash: destination, bodyHash: bodyHash, selfEvidenceKind: nil, chatID: nil,
            createdAt: created, expiresAt: created.addingTimeInterval(Double(config.outboundMaxAgeSeconds)),
            stage: .reserved)
        if let rejection {
            record.stage = .terminal
            record.terminalCode = rejection
            record.terminalAt = clock.now()
            record.deadLetterPending = rejection == "outbound_dove_body"
        }
        persisted.outbound.records.append(record)
        guard persist() else {
            outboundPersistenceBlocked = true
            outboundLog("outbound_state_save_failed")
            return
        }
        if let rejection {
            if rejection == "outbound_dove_body" { retryOutboundDeadLetters() }
            outboundLog(rejection)
            return
        }
        await resumeOutbound(id, body: body, rawDove: rawDove)
    }

    private func outboundBody(_ raw: String) -> (body: String?, error: String?) {
        let normalized = TextNormalizer.nfc(raw)
        guard !Signal.matches(normalized) else { return (nil, "outbound_signal_body") }
        guard normalized.unicodeScalars.count <= 8000, !normalized.contains("\0") else {
            return (nil, "outbound_text_invalid")
        }
        switch ReplyComposer.split(body: normalized, marker: config.replyMarker) {
        case .emptyBody: return (nil, "outbound_empty_body")
        case .stillSignal: return (nil, "outbound_signal_body")
        case .send(let body):
            let normalizedBody = TextNormalizer.nfc(body)
            guard normalizedBody.unicodeScalars.count <= 8000 else { return (nil, "outbound_text_invalid") }
            return (normalizedBody, nil)
        }
    }

    private enum OutboundDestination {
        case ready(Int64, OutboundSelfEvidence?)
        case hold
        case reject(String)
    }

    private func outboundDestination(_ target: OutboundTarget?, guidHash: String) -> OutboundDestination {
        guard let target, let guid = config.outboundTargets[target.rawValue], !guid.isEmpty else { return .reject("outbound_target_unset") }
        guard !config.outboundTargetCollision else { return .reject("outbound_target_collision") }
        guard config.outboundEnabled else { return .reject("outbound_source_changed") }
        guard OutboundHash.digest(kind: "destination", values: [guid]) == guidHash else { return .reject("outbound_target_changed") }
        guard directoryChecked, listFetchFailingSince == nil, parseProblem != .partial else {
            outboundLog("outbound_held_unverified")
            return .hold
        }
        let matches = outboundDirectory.filter { $0.guid == guid }
        guard matches.count == 1 else {
            outboundLog(matches.count > 1 ? "outbound_target_ambiguous" : "outbound_held_unverified")
            return .hold
        }
        noticeLog.resolve(["outbound_held_unverified", "outbound_target_ambiguous"])
        let chat = matches[0]
        let group = SelfChat.resolveGroup(flag: chat.isGroup, chatGUID: chat.guid, chatIdentifier: chat.identifier)
        var selfEvidence: OutboundSelfEvidence?
        switch target {
        case .family:
            guard config.groupChatGUIDs.contains(guid) else { return .reject("outbound_family_not_configured") }
            guard group else { return .reject("outbound_family_not_group") }
        case .self:
            guard !group else { return .reject("outbound_self_not_self") }
            if config.selfChatIDs.contains(chat.id) {
                selfEvidence = .selfChatIDs
            } else {
                let ownHandles = directoryHandleKeys.union(watchHandleKeys)
                let people = chat.participants.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard chat.participantsKnown, !people.isEmpty else {
                    outboundLog("outbound_held_unverified")
                    return .hold
                }
                guard people.count == 1, let participant = SenderHandle.normalize(people[0]) else {
                    return .reject("outbound_self_not_self")
                }
                guard !ownHandles.isEmpty else {
                    outboundLog("outbound_held_unverified")
                    return .hold
                }
                guard ownHandles.contains(participant) else { return .reject("outbound_self_not_self") }
                selfEvidence = .participant(participant)
            }
        }
        guard allowsSend(chat.id) else { return .reject("outbound_chat_disabled") }
        var expected = configGroups.expectedGUIDs(for: chat.id)
        expected.append(contentsOf: allowlist.entries.filter { $0.id == chat.id }.map(\.guid))
        guard !expected.isEmpty, expected.allSatisfy({ !$0.isEmpty && $0 == guid }), directoryGUIDs[chat.id] == guid else {
            return .reject("outbound_guid_mismatch")
        }
        return .ready(chat.id, selfEvidence)
    }

    private func reserveOutboundEvidence(_ id: String, target: OutboundTarget?, current: OutboundSelfEvidence?) -> Bool {
        guard let index = outboundRecordIndex(id) else { return false }
        guard target == .self else { return current == nil && persisted.outbound.records[index].selfEvidenceKind == nil }
        guard let current else { return false }
        let kind = current.kind
        if let saved = persisted.outbound.records[index].selfEvidenceKind {
            guard saved == kind else { return false }
        } else {
            persisted.outbound.records[index].selfEvidenceKind = kind
        }
        if case .participant(let value) = current {
            if let previous = outboundParticipantEvidence[id], previous != value { return false }
            outboundParticipantEvidence[id] = value
        }
        return true
    }

    private func outboundEvidenceMatches(_ id: String, target: OutboundTarget?, current: OutboundSelfEvidence?) -> Bool {
        guard let index = outboundRecordIndex(id) else { return false }
        guard target == .self else { return current == nil && persisted.outbound.records[index].selfEvidenceKind == nil }
        guard let current, persisted.outbound.records[index].selfEvidenceKind == current.kind else { return false }
        if case .participant(let value) = current {
            if let previous = outboundParticipantEvidence[id], previous != value { return false }
            outboundParticipantEvidence[id] = value
        }
        return true
    }

    private func resumeOutbound(_ id: String, body raw: String, rawDove: Bool) async {
        guard let index = outboundRecordIndex(id), !inFlightReplyIDs.contains(id),
              !holds.contains(where: { $0.replyID == id }), persisted.outbound.records[index].stage != .terminal else { return }
        let record = persisted.outbound.records[index]
        guard clock.now() < record.expiresAt else { terminateOutbound(id, code: "outbound_expired"); return }
        guard record.sourceHash == outboundSourceHash() else { terminateOutbound(id, code: "outbound_source_changed"); return }
        switch outboundDestination(record.target, guidHash: record.destinationHash) {
        case .reject(let code): terminateOutbound(id, code: code)
        case .hold: return
        case .ready(let chatID, let evidence):
            if let previous = record.chatID, previous != chatID {
                terminateOutbound(id, code: "outbound_target_changed"); return
            }
            guard reserveOutboundEvidence(id, target: record.target, current: evidence) else {
                terminateOutbound(id, code: "outbound_target_changed"); return
            }
            if inFlightReplyChats.values.contains(chatID) || persisted.partialReplies.contains(where: { $0.chatID == chatID && $0.replyID != id }) { return }
            persisted.outbound.records[index].chatID = chatID
            guard let body = outboundBody(raw).body else {
                terminateOutbound(id, code: "outbound_idempotency_conflict")
                return
            }
            guard persist() else {
                outboundPersistenceBlocked = true
                outboundLog("outbound_state_save_failed")
                return
            }
            await performSend(replyID: id, chatID: chatID,
                part: record.stage == .bodyReady ? .body : .marker, body: body,
                attempts: 1, reserved: false, pauseReason: .appleEventNotStarted,
                createdAt: record.createdAt, origin: .outbound(rawDove: rawDove))
        }
    }

    private func outboundAuthorizationMatches(replyID: String, chatID: Int64) -> Bool {
        guard let index = outboundRecordIndex(replyID) else { return true }
        let record = persisted.outbound.records[index]
        guard record.stage != .terminal, record.sourceHash == outboundSourceHash(), clock.now() < record.expiresAt else { return false }
        if case .ready(let current, let evidence) = outboundDestination(record.target, guidHash: record.destinationHash) {
            return current == chatID && outboundEvidenceMatches(replyID, target: record.target, current: evidence)
        }
        return false
    }

    private func sendGuard(replyID: String, chatID: Int64, body: String, part: SendPart,
        attempts: Int, createdAt: Date, origin: SendOrigin) -> Bool {
        switch origin {
        case .dove(let chatGUIDHash):
            guard let guid = config.doveChatGUIDs.first(where: {
                config.groupChatGUIDs.contains($0) && SHA256.hex(Data($0.utf8)) == chatGUIDHash
            }) else {
                dropDisabled(replyID: replyID, chatID: chatID, code: "reply_dove_chat_disabled")
                return false
            }
            if rejectMismatchedChatGuid(replyID: replyID, chatID: chatID, doveGUID: guid) {
                if !persisted.handledReplyIDs.contains(replyID) {
                    hold(replyID: replyID, chatID: chatID, part: part, body: body, reason: .appleEventNotStarted,
                        attempts: attempts, logIt: false, createdAt: createdAt, origin: origin)
                }
                return false
            }
            guard isDoveChat(chatID, guid: guid) else {
                dropDisabled(replyID: replyID, chatID: chatID, code: "reply_dove_chat_disabled")
                return false
            }
            return true
        case .lamp:
            if isDoveChat(chatID) && DoveSignal.matches(body) {
                dropDisabled(replyID: replyID, chatID: chatID, code: "reply_still_matches_dove")
                return false
            }
            return true
        case .outbound(let rawDove):
            if isDoveChat(chatID) && (rawDove || DoveSignal.matches(body)) {
                terminateOutbound(replyID, code: "outbound_dove_body", deadLetter: true)
                return false
            }
        }
        guard let index = outboundRecordIndex(replyID) else { return false }
        let record = persisted.outbound.records[index]
        guard !outboundPersistenceBlocked, record.stage != .terminal else { return false }
        guard clock.now() < record.expiresAt else { terminateOutbound(replyID, code: "outbound_expired"); return false }
        guard record.sourceHash == outboundSourceHash(), config.outboundEnabled else {
            terminateOutbound(replyID, code: "outbound_source_changed"); return false
        }
        switch outboundDestination(record.target, guidHash: record.destinationHash) {
        case .reject(let code): terminateOutbound(replyID, code: code); return false
        case .hold:
            hold(replyID: replyID, chatID: chatID, part: part, body: body, reason: .appleEventNotStarted,
                attempts: attempts, logIt: false, createdAt: createdAt, origin: origin)
            return false
        case .ready(let current, let evidence):
            guard current == chatID, outboundEvidenceMatches(replyID, target: record.target, current: evidence) else {
                terminateOutbound(replyID, code: "outbound_target_changed"); return false
            }
        }
        return true
    }

    private func terminateOutbound(_ id: String, code: String, deadLetter: Bool = false) {
        guard let index = outboundRecordIndex(id) else { return }
        persisted.outbound.records[index].stage = .terminal
        persisted.outbound.records[index].terminalCode = code
        persisted.outbound.records[index].terminalAt = clock.now()
        persisted.outbound.records[index].deadLetterPending = deadLetter
        holds.removeAll { $0.replyID == id }
        persisted.pendingSends.removeAll { $0.replyID == id }
        persisted.partialReplies.removeAll { $0.replyID == id }
        bodyResendSavePending.remove(id)
        outboundIntentFingerprints.removeValue(forKey: id)
        outboundParticipantEvidence.removeValue(forKey: id)
        outboundLog(code)
        guard persist() else {
            outboundPersistenceBlocked = true
            outboundLog("outbound_state_save_failed")
            return
        }
        if deadLetter { retryOutboundDeadLetters() }
    }

    private func outboundLog(_ code: String) {
        let continued: Set<String> = ["outbound_source_conflict", "outbound_target_collision", "outbound_fetch_failed",
            "outbound_held_unverified", "outbound_target_ambiguous", "outbound_ledger_full", "outbound_state_save_failed",
            "outbound_held_locked", "outbound_held_not_started", "outbound_held_rate_limited", "outbound_source_invalid",
            "outbound_held_body_unavailable", "outbound_token_missing", "outbound_token_mode", "outbound_token_empty", "outbound_token_unreadable"]
        if continued.contains(code), !noticeLog.shouldLog(code) { return }
        let warning: Set<String> = ["outbound_bad_entry", "outbound_unknown_target", "outbound_empty_body",
            "outbound_signal_body", "outbound_text_invalid", "outbound_held_unverified", "outbound_target_ambiguous",
            "outbound_held_locked", "outbound_held_not_started", "outbound_held_rate_limited", "outbound_held_body_unavailable"]
        let info: Set<String> = ["outbound_expired", "outbound_chat_disabled", "outbound_target_changed",
            "outbound_duplicate_key", "outbound_duplicate_body", "outbound_marker_sent",
            "outbound_body_sent", "outbound_db_reset", "outbound_source_changed"]
        let level: LogLevel = info.contains(code) ? .info : warning.contains(code) ? .warning : .error
        log.record(level: level, code: code, chatID: nil, guid: nil, rowid: nil)
    }

    private func sendLog(replyID: String, level: LogLevel, code: String, chatID: Int64?, guid: String?, rowid: Int64?, detail: String? = nil) {
        guard isOutbound(replyID) else {
            log.record(level: level, code: code, chatID: chatID, guid: guid, rowid: rowid, detail: detail)
            return
        }
        if code != "apple_event_1712" { noticeLog.resolve(["outbound_held_not_started"]) }
        if screenLock != .locked { noticeLog.resolve(["outbound_held_locked"]) }
        if let chatID, !persisted.haltedChatIDs.contains(chatID) { noticeLog.resolve(["outbound_held_rate_limited"]) }
        if code == "marker_image_unavailable" || code == "marker_image_failed" {
            log.record(level: level, code: code, chatID: nil, guid: nil, rowid: nil, detail: detail)
            return
        }
        let mapped: String
        switch code {
        case "reply_sent": mapped = detail == "resend" ? "outbound_body_resent" : detail == "body" ? "outbound_body_sent" : "outbound_marker_sent"
        case "screen_locked": mapped = "outbound_held_locked"
        case "apple_event_1712": mapped = "outbound_held_not_started"
        case "rate_limited": mapped = "outbound_held_rate_limited"
        default: mapped = code.hasPrefix("outbound_") ? code : "outbound_" + code
        }
        outboundLog(mapped)
    }

    private static func settleOutboundInterrupted(state: inout PersistedState, store: any StatePersisting, log: any GenieLog, now: Date) -> Bool {
        var needsTransitionSave = false
        for index in state.outbound.records.indices {
            let record = state.outbound.records[index]
            if record.stage == .markerInFlight || record.stage == .bodyInFlight {
                state.outbound.records[index].stage = .terminal
                state.outbound.records[index].terminalCode = record.stage == .bodyInFlight
                    ? "outbound_body_send_interrupted" : "outbound_send_interrupted"
                state.outbound.records[index].terminalAt = now
                state.outbound.records[index].deadLetterPending = true
                state.pendingSends.removeAll { $0.replyID == record.id }
                state.partialReplies.removeAll { $0.replyID == record.id }
                needsTransitionSave = true
            }
        }
        if needsTransitionSave {
            do { try store.save(state) }
            catch {
                log.record(level: .error, code: "outbound_state_save_failed", chatID: nil, guid: nil, rowid: nil)
                return false
            }
        }

        var cleared: [Int] = []
        for index in state.outbound.records.indices where state.outbound.records[index].deadLetterPending {
            let record = state.outbound.records[index]
            do {
                try store.appendDeadLetter(DeadLetterEntry(ts: ISO8601.string(from: now), kind: "outbound",
                    chatID: nil, guid: nil, rowid: nil, attempts: 1,
                    error: record.terminalCode ?? "outbound_send_interrupted"))
                state.outbound.records[index].deadLetterPending = false
                cleared.append(index)
            } catch {
                log.record(level: .error, code: "outbound_deadletter_write_failed", chatID: nil, guid: nil, rowid: nil)
            }
        }
        guard !cleared.isEmpty else { return true }
        do { try store.save(state); return true }
        catch {
            for index in cleared { state.outbound.records[index].deadLetterPending = true }
            log.record(level: .error, code: "outbound_state_save_failed", chatID: nil, guid: nil, rowid: nil)
            return false
        }
    }
}
