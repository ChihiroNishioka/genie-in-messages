import Foundation

public enum WindowRestorationPolicy {
    public static func disable(in defaults: UserDefaults) {
        defaults.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
}
