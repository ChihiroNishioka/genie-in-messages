import CoreGraphics
import Foundation
import GenieCore

/// 公開の `CGSessionCopyCurrentDictionary` を直接呼ぶ。判定できないときは unknown。
/// ロック中だけ `CGSSessionScreenIsLocked` がある、という報告に合わせ、キーが無ければ解除とみなす。
/// 辞書自体が取れないときは unknown。`-1712` の保留は送信側の安全網。
package struct ScreenLockProbe: ScreenLockChecking {
    private let monitor = LockMonitor()

    package init() {}

    package func state() async -> ScreenLockState {
        monitor.current()
    }

    package func observe(_ handler: @escaping @Sendable (ScreenLockState) -> Void) {
        monitor.setHandler(handler)
    }
}

final class LockMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var notified: ScreenLockState?
    private var tokens: [NSObjectProtocol] = []
    private var onChange: (@Sendable (ScreenLockState) -> Void)?

    init() {
        let center = DistributedNotificationCenter.default()
        tokens.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.set(.locked)
        })
        tokens.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.set(.unlocked)
        })
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        for token in tokens {
            center.removeObserver(token)
        }
    }

    func setHandler(_ handler: @escaping @Sendable (ScreenLockState) -> Void) {
        lock.lock()
        onChange = handler
        lock.unlock()
    }

    func current() -> ScreenLockState {
        let probed = ScreenLockStatus.probe()
        lock.lock()
        defer { lock.unlock() }
        if probed != .unknown {
            notified = probed
            return probed
        }
        return notified ?? .unknown
    }

    private func set(_ state: ScreenLockState) {
        lock.lock()
        notified = state
        let handler = onChange
        lock.unlock()
        handler?(state)
    }
}

enum ScreenLockStatus {
    static func probe() -> ScreenLockState {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return .unknown
        }
        if dictionary["CGSSessionScreenIsLocked"] == nil {
            return .unlocked
        }
        if let locked = dictionary["CGSSessionScreenIsLocked"] as? Bool {
            return locked ? .locked : .unlocked
        }
        if let number = dictionary["CGSSessionScreenIsLocked"] as? NSNumber {
            return number.boolValue ? .locked : .unlocked
        }
        return .unlocked
    }
}
