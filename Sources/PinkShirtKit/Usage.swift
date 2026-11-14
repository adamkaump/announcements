import Foundation
import Security
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension View {
    /// Counts this install once per day toward the app's daily, weekly and monthly users, with no identifier.
    ///
    ///     ContentView()
    ///         .usageReporting(app: "pinpoint")
    ///
    /// Each report says only whether it's also the install's first of the week and of the month, plus the app
    /// version, platform, device model, system version and language. While the app is active it also sends a
    /// heartbeat each minute, holding only the app's name, for sessions, time spent and people using it now. The
    /// heartbeats follow the app's active state, so they continue while a full-screen player covers this view.
    /// Debug builds don't report unless launched with `-PSFUsageDebug YES`. People turn it off with
    /// `UsageReporting.isEnabled`.
    public func usageReporting(app: String, isEnabled: Bool = true) -> some View {
        modifier(UsageModifier(app: app, isEnabled: isEnabled))
    }
}

/// The app's switch for anonymous usage reports, announcement views included. On unless turned off.
public enum UsageReporting {
    /// Bind a toggle to this with `@AppStorage(UsageReporting.disabledKey)`, where true means off.
    public static let disabledKey = "PSFUsage.disabled"
    static let lastDayKey = "PSFUsage.lastDay"
    static let lastWeekKey = "PSFUsage.lastWeek"
    static let lastMonthKey = "PSFUsage.lastMonth"
    static let debugKey = "PSFUsageDebug"

    public static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: disabledKey) }
        set { UserDefaults.standard.set(!newValue, forKey: disabledKey) }
    }

    /// Off in debug builds, simulators and Apple's virtual devices, so testing doesn't count as users.
    static var mayReport: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: debugKey) else { return false }
        #endif
        return isEnabled && !DeviceContext.isVirtual
        #endif
    }

    /// How often an app on screen says so. The server counts heartbeats this recent as people using it now.
    static let heartbeatInterval: TimeInterval = 60
    /// Coming back on screen within this long continues the session, so a quick trip to another app isn't a new one.
    static let sessionGap: TimeInterval = 5 * 60

    /// Whether the next heartbeat starts a session, given when the app was last on screen.
    static func startsSession(lastOnScreen: Date?, now: Date) -> Bool {
        lastOnScreen.map { now.timeIntervalSince($0) > sessionGap } ?? true
    }

    /// How long to wait before the next heartbeat. Coming back on screen within a minute of the last one waits out
    /// the rest of that minute, so a quick trip to Control Center doesn't add a minute.
    static func heartbeatDelay(lastHeartbeat: Date?, now: Date) -> TimeInterval {
        guard let lastHeartbeat else { return 0 }
        return min(max(0, heartbeatInterval - now.timeIntervalSince(lastHeartbeat)), heartbeatInterval)
    }
}

/// Sends a heartbeat each minute while the app is active, and the daily report when it becomes active.
///
/// Follows the app's own active state rather than a view's lifetime: a view's tasks are cancelled when something
/// covers it, such as a full-screen video player presented over the root view, which stopped the heartbeats for
/// as long as the video played.
@MainActor final class UsageMonitor {
    static let shared = UsageMonitor()

    private var app: String?
    private var heartbeats: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var lastOnScreen: Date?
    private var lastHeartbeat: Date?

    /// Starts following the app's active state. Later calls do nothing, even from several windows.
    func start(app: String) {
        guard self.app == nil else { return }
        self.app = app
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: Self.didBecomeActive, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { UsageMonitor.shared.becameActive() }
            },
            center.addObserver(forName: Self.willResignActive, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { UsageMonitor.shared.resignedActive() }
            },
        ]
        if Self.isActive { becameActive() }
    }

    private func becameActive() {
        guard let app, heartbeats == nil else { return }
        Task { await UsageReporting.reportIfNeeded(app: app) }
        heartbeats = Task { await beat(app: app) }
    }

    private func resignedActive() {
        heartbeats?.cancel()
        heartbeats = nil
        if lastHeartbeat != nil { lastOnScreen = .now }
    }

    private func beat(app: String) async {
        guard UsageReporting.mayReport else { return }
        let delay = UsageReporting.heartbeatDelay(lastHeartbeat: lastHeartbeat, now: .now)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        var start = UsageReporting.startsSession(lastOnScreen: lastOnScreen, now: .now)
        while !Task.isCancelled {
            lastHeartbeat = .now
            lastOnScreen = .now
            let body: [String: any Sendable] = ["app": app, "start": start]
            Task.detached { _ = await API.post("v1/heartbeat", body) }
            start = false
            try? await Task.sleep(for: .seconds(UsageReporting.heartbeatInterval))
        }
    }

    #if os(macOS)
    private static let didBecomeActive = NSApplication.didBecomeActiveNotification
    private static let willResignActive = NSApplication.willResignActiveNotification
    private static var isActive: Bool { NSApplication.shared.isActive }
    #else
    private static let didBecomeActive = UIApplication.didBecomeActiveNotification
    private static let willResignActive = UIApplication.willResignActiveNotification
    private static var isActive: Bool { UIApplication.shared.applicationState == .active }
    #endif
}

extension UsageReporting {
    /// The periods a report sent at `date` would be the first of, in UTC to match the server's days.
    struct Periods: Equatable, Codable {
        var day: String
        var week: String
        var month: String

        init(day: String, week: String, month: String) {
            self.day = day
            self.week = week
            self.month = month
        }

        init(_ date: Date) {
            var calendar = Calendar(identifier: .iso8601)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let parts = calendar.dateComponents([.year, .month, .day, .yearForWeekOfYear, .weekOfYear], from: date)
            day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            week = String(format: "%04d-W%02d", parts.yearForWeekOfYear!, parts.weekOfYear!)
            month = String(format: "%04d-%02d", parts.year!, parts.month!)
        }
    }

    @MainActor private static var isSending = false

    /// Sends today's report if this install hasn't yet. A failed send is tried again on the next activation.
    @MainActor static func reportIfNeeded(app: String, now: Date = .now) async {
        guard mayReport, !isSending else { return }
        let periods = Periods(now)
        let last = LastReport.load()
        guard last?.day != periods.day else { return }
        isSending = true
        defer { isSending = false }

        var body = DeviceContext.current(app: app)
        body["firstOfWeek"] = last?.week != periods.week
        body["firstOfMonth"] = last?.month != periods.month
        guard await API.post("v1/ping", body) != nil else { return }
        LastReport.save(periods)
    }

    /// An announcement was shown, or its link was tapped.
    static func recordAnnouncement(_ announcement: ResolvedAnnouncement, kind: String) {
        guard mayReport, let app = announcement.app else { return }
        let body: [String: any Sendable] = ["app": app, "announcement": announcement.id, "kind": kind, "language": announcement.language]
        Task.detached { _ = await API.post("v1/announcement-events", body) }
    }
}

/// When this device last reported. Kept in the Keychain, which on iPhone and iPad survives deleting and
/// reinstalling the app, so a reinstall the same day or week isn't counted as another person. It holds only the
/// dates, never anything sent anywhere. UserDefaults is the fallback if the Keychain refuses.
enum LastReport {
    private static var query: [CFString: Any] { [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "PSFUsage",
        kSecAttrAccount: "lastReport",
        kSecUseDataProtectionKeychain: true,
    ] }

    static func load() -> UsageReporting.Periods? {
        var request = query
        request[kSecReturnData] = true
        var result: CFTypeRef?
        if SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
           let periods = try? JSONDecoder().decode(UsageReporting.Periods.self, from: data) {
            return periods
        }
        let defaults = UserDefaults.standard
        guard let day = defaults.string(forKey: UsageReporting.lastDayKey) else { return nil }
        return .init(day: day, week: defaults.string(forKey: UsageReporting.lastWeekKey) ?? "",
                     month: defaults.string(forKey: UsageReporting.lastMonthKey) ?? "")
    }

    static func save(_ periods: UsageReporting.Periods) {
        let defaults = UserDefaults.standard
        defaults.set(periods.day, forKey: UsageReporting.lastDayKey)
        defaults.set(periods.week, forKey: UsageReporting.lastWeekKey)
        defaults.set(periods.month, forKey: UsageReporting.lastMonthKey)
        guard let data = try? JSONEncoder().encode(periods) else { return }
        if SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

struct UsageModifier: ViewModifier {
    let app: String
    let isEnabled: Bool

    func body(content: Content) -> some View {
        // Heartbeats and the daily report follow the app's active state, not this view: apps stay open for days,
        // and a full-screen player over the root view would otherwise stop them.
        content.task {
            guard isEnabled else { return }
            UsageMonitor.shared.start(app: app)
        }
    }
}

/// What every report and feedback message says about where it came from.
enum DeviceContext {
    @MainActor static func current(app: String) -> [String: any Sendable] {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "app": app,
            "platform": platform,
            "device": model,
            "os": "\(os.majorVersion).\(os.minorVersion)",
            "version": info["CFBundleShortVersionString"] as? String ?? "?",
            "build": info["CFBundleVersion"] as? String ?? "?",
            "language": Locale.preferredLanguages.first ?? "?",
        ]
    }

    @MainActor static var platform: String {
        #if os(macOS)
        "macOS"
        #elseif os(visionOS)
        "visionOS"
        #elseif os(tvOS)
        "tvOS"
        #else
        ProcessInfo.processInfo.isiOSAppOnMac ? "macOS" : UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
    }

    /// Apple's virtual iPhones and Macs (iPhone99,10, VirtualMac2,1), which launch each uploaded build for
    /// App Store Connect.
    static var isVirtual: Bool {
        model.contains("99,") || model.hasPrefix("Virtual")
    }

    /// The hardware model, such as iPhone16,2 or Mac14,3.
    static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if os(macOS)
        return sysctlString("hw.model") ?? "Mac"
        #else
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        #endif
    }

    #if os(macOS)
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    #endif
}

/// Pink Shirt Friday's backend, the pinkshirtfriday-api Worker.
enum API {
    static let baseURL = URL(string: "https://pinkshirtfriday-api.pinkshirtfriday-api.workers.dev/")!

    enum Failure: Error {
        case offline
        case tooManyRequests
        case rejected(String)
    }

    /// The response body, or nil on any failure. For callers that don't need to say why.
    static func post(_ path: String, _ body: [String: any Sendable]) async -> Data? {
        try? await send(path, body)
    }

    static func send(_ path: String, _ body: [String: any Sendable]) async throws(Failure) -> Data {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { throw .offline }
        switch status {
        case 200..<300: return data
        case 429: throw .tooManyRequests
        default:
            struct Message: Decodable { var error: String }
            throw .rejected((try? JSONDecoder().decode(Message.self, from: data))?.error ?? "HTTP \(status)")
        }
    }
}
