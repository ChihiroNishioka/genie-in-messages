import Darwin
import Foundation
import GenieCore

/// 画面ロックは送信前に見る。判定できないときは送って、`-1712` の保留に任せる。
package struct ScreenLockProbe: ScreenLockChecking {
    package func isLocked() async -> Bool {
        ScreenLockStatus.current()
    }
}

enum ScreenLockStatus {
    static func current() -> Bool {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ) else {
            return false
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "CGSessionCopyCurrentDictionary") else {
            return false
        }
        typealias CopyDictionary = @convention(c) () -> Unmanaged<CFDictionary>?
        let copy = unsafeBitCast(symbol, to: CopyDictionary.self)
        guard let unmanaged = copy() else { return false }
        let dictionary = unmanaged.takeRetainedValue() as NSDictionary
        if let locked = dictionary["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        if let number = dictionary["CGSSessionScreenIsLocked"] as? NSNumber {
            return number.boolValue
        }
        return false
    }
}
