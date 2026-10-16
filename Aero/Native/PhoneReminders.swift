import Foundation
import UserNotifications

/// What PhoneReminders needs of the system's notification centre; `SystemNotifications` is the real one, tests give a stand-in.
protocol NotificationScheduling {
    func requestAuthorization() async -> Bool
    func pendingIdentifiers() async -> [String]
    func remove(_ identifiers: [String])
    func schedule(identifier: String, title: String, at: DateComponents) async throws
}

/// Reminders are the phone's own: scheduled as local notifications from the phone's records, so one fires with the phone offline and no
/// PC. iOS keeps at most 64 pending local notifications per app and discards the rest, so only the nearest are scheduled, and the set is
/// made again whenever the records change and whenever the app opens (top up).
///
/// The limit: "there is a limit of 64 for how many simultaneous notification requests can be active/pending at one time per app. This is a
/// system limit and there is no way around it." (an Apple engineer, Apple Developer Forums, thread 811171, January 2026). Apple's
/// UNUserNotificationCenter page does not state the number; the older UILocalNotification text said the system keeps the soonest-firing
/// 64 and discards the rest.
final class PhoneReminders {
    struct Upcoming: Equatable {
        var oid: String
        var title: String
        /// 'YYYY-MM-DD HH:MM', the phone's local time
        var fire: String
    }

    static let maxPending = 64
    /// Ours are told apart from anything else by this start of the identifier.
    static let prefix = "fingus.org."

    private let center: NotificationScheduling
    private var asked = false

    init(center: NotificationScheduling) {
        self.center = center
    }

    /// The identifier of one told time: the record and the minute.
    static func identifier(_ u: Upcoming) -> String { prefix + u.oid + "." + u.fire.replacingOccurrences(of: " ", with: "T") }

    /// 'YYYY-MM-DD HH:MM' as the calendar fields a trigger needs; nil when it is not that shape.
    static func components(_ fire: String) -> DateComponents? {
        let parts = fire.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" || $0 == "T" }).compactMap { Int($0) }
        guard parts.count == 5 else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4])
    }

    /// Make the scheduled set exactly the nearest `maxPending` of `upcoming` (given nearest first), removing ours that are no longer
    /// wanted and adding the missing. Asks for permission the first time there is something to tell.
    func replace(with upcoming: [Upcoming]) async {
        let want = Array(upcoming.prefix(Self.maxPending))
        if !want.isEmpty, !asked {
            asked = true
            if !(await center.requestAuthorization()) { return }
        }
        let wanted = Dictionary(want.map { (Self.identifier($0), $0) }, uniquingKeysWith: { a, _ in a })
        let have = Set(await center.pendingIdentifiers().filter { $0.hasPrefix(Self.prefix) })
        center.remove(Array(have.subtracting(wanted.keys)))
        for (id, u) in wanted.sorted(by: { $0.value.fire < $1.value.fire }) where !have.contains(id) {
            guard let c = Self.components(u.fire) else { continue }
            try? await center.schedule(identifier: id, title: u.title, at: c)
        }
    }
}

/// The real notification centre.
struct SystemNotifications: NotificationScheduling {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func remove(_ identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func schedule(identifier: String, title: String, at: DateComponents) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: at, repeats: false)
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}
