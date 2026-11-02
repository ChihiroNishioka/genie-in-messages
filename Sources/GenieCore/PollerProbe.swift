import Foundation

package protocol PollerProbe: Sendable {
    func chatsReadReturned() async
    func chatsApplied() async
    func initialWaitRegistered() async
}
