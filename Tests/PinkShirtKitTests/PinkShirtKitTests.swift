import Foundation
import Testing
@testable import PinkShirtKit

@Suite struct VersionTests {
    @Test func comparesNumerically() {
        #expect(AppVersion("1.9") < AppVersion("1.10"))
        #expect(AppVersion("2") == AppVersion("2.0.0"))
        #expect(!(AppVersion("2.1") < AppVersion("2.1")))
    }

    @Test func rules() {
        #expect(VersionRule(below: "2.1").matches("2.0.3"))
        #expect(!VersionRule(below: "2.1").matches("2.1"))
        #expect(VersionRule(only: ["1.4", "1.5"]).matches("1.5.0"))
        #expect(!VersionRule(only: ["1.4"]).matches("1.5"))
    }

    @Test func belowBuild() {
        let rule = VersionRule(below: "2.1", belowBuild: "45")
        #expect(rule.matches("2.0.9", build: "60"))
        #expect(rule.matches("2.1", build: "44"))
        #expect(!rule.matches("2.1", build: "45"))
        #expect(!rule.matches("2.1"))
        #expect(!rule.matches("2.2", build: "1"))
        #expect(!VersionRule(below: "2.1").matches("2.1", build: "1"))
    }
}

@Suite struct SelectionTests {
    static let json = """
    {
      "schema": 1,
      "announcements": [
        {
          "id": "old",
          "publishedAt": "2026-10-01T12:00:00Z",
          "expiresAt": "2026-12-01T12:00:00Z",
          "localizations": { "en": { "title": "Old", "body": "Old news" } }
        },
        {
          "id": "new",
          "publishedAt": "2026-11-01T12:00:00Z",
          "expiresAt": "2026-12-01T12:00:00Z",
          "versions": { "below": "2.0" },
          "link": "https://pinkshirtfriday.com/pinpoint/",
          "localizations": {
            "en": { "title": "Update", "body": "Please **update**.", "linkTitle": "Update" },
            "de": { "title": "Aktualisieren", "body": "Bitte **aktualisieren**.", "linkTitle": "Aktualisieren" },
            "zh-Hant": { "title": "更新", "body": "請更新。", "linkTitle": "更新" },
            "pt-BR": { "title": "Atualize", "body": "Atualize o app.", "linkTitle": "" }
          }
        },
        {
          "id": "expired",
          "publishedAt": "2026-09-01T12:00:00Z",
          "expiresAt": "2026-10-01T12:00:00Z",
          "localizations": { "en": { "title": "Gone", "body": "" } }
        }
      ]
    }
    """
    static let feed = try! AnnouncementFeed.decoder.decode(AnnouncementFeed.self, from: Data(json.utf8))
    static let now = ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z")!

    @MainActor func pick(version: String = "1.5", seen: Set<String> = [], languages: [String] = ["en-US"]) -> ResolvedAnnouncement? {
        AnnouncementChecker.select(from: Self.feed, appVersion: version, seen: seen, preferences: languages, now: Self.now)
    }

    @MainActor @Test func newestUnseenFirst() {
        #expect(pick()?.id == "new")
        #expect(pick(seen: ["new"])?.id == "old")
        #expect(pick(seen: ["new", "old"]) == nil)
    }

    @MainActor @Test func versionRuleApplies() {
        #expect(pick(version: "2.0")?.id == "old")
    }

    @MainActor @Test func picksLanguage() {
        #expect(pick(languages: ["de-AT", "en"])?.language == "de")
        #expect(pick(languages: ["zh-Hant-TW"])?.language == "zh-Hant")
        #expect(pick(languages: ["pt-PT"])?.language == "pt-BR")
        #expect(pick(languages: ["fi-FI"])?.language == "en")
        #expect(pick(languages: ["fi-FI", "de-DE"])?.language == "de")
    }

    @MainActor @Test func futureSchemaIsIgnored() {
        var feed = Self.feed
        feed.schema = 2
        #expect(AnnouncementChecker.select(from: feed, appVersion: "1.0", seen: [], preferences: ["en"], now: Self.now) == nil)
    }

    @MainActor @Test func buttonLabelsFollowTheAnnouncementLanguage() {
        #expect(AnnouncementSheet.localized("Learn More", language: "de") == "Mehr erfahren")
        #expect(AnnouncementSheet.localized("OK", language: "ko") == "확인")
        #expect(AnnouncementSheet.localized("OK", language: "en") == "OK")
    }
}

@Suite struct UsageTests {
    @Test func periodsUseUTCAndISOWeeks() throws {
        let november = try Date("2026-11-02T23:30:00Z", strategy: .iso8601)
        #expect(UsageReporting.Periods(november) == .init(day: "2026-11-02", week: "2026-W45", month: "2026-11"))
        // January 1, 2027 is a Friday, so it's still in 2026's last ISO week.
        let newYear = try Date("2027-01-01T08:00:00Z", strategy: .iso8601)
        #expect(UsageReporting.Periods(newYear) == .init(day: "2027-01-01", week: "2026-W53", month: "2027-01"))
    }

}

@Suite struct HeartbeatTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func sessions() {
        #expect(UsageReporting.startsSession(lastOnScreen: nil, now: now))
        #expect(!UsageReporting.startsSession(lastOnScreen: now.addingTimeInterval(-120), now: now))
        #expect(UsageReporting.startsSession(lastOnScreen: now.addingTimeInterval(-301), now: now))
    }

    @Test func delay() {
        #expect(UsageReporting.heartbeatDelay(lastHeartbeat: nil, now: now) == 0)
        #expect(UsageReporting.heartbeatDelay(lastHeartbeat: now.addingTimeInterval(-20), now: now) == 40)
        #expect(UsageReporting.heartbeatDelay(lastHeartbeat: now.addingTimeInterval(-90), now: now) == 0)
        // A clock that moved backwards never waits more than one interval.
        #expect(UsageReporting.heartbeatDelay(lastHeartbeat: now.addingTimeInterval(30), now: now) == 60)
    }
}
