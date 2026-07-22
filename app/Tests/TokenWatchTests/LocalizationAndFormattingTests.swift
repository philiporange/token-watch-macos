import Foundation
import Testing
@testable import TokenWatch

@Suite struct LocalizationAndFormattingTests {

    // MARK: - Non-English localization

    @Test func nonEnglishLocalization() {
        let es = Loc(lang: .spanish)
        let en = Loc(lang: .english)

        #expect(es.windowLabel(.fiveHour) == "5h")
        #expect(!es.windowLabel(.weekly).isEmpty)

        let translated = es.displayMessage("Loading…")
        #expect(translated != "Loading…")
        #expect(translated != "—")
        #expect(!translated.isEmpty)

        #expect(!es.launchAtStartup.isEmpty)
        #expect(es.launchAtStartup != en.launchAtStartup)
    }

    // MARK: - English localization

    @Test func englishInsightAndStatus() {
        let en = Loc(lang: .english)

        #expect(en.insightMessage(delta: -11) == "11% over pace")
        #expect(en.insightMessage(delta: 9) == "9% to spare")

        let codexNotInstalled = AgentStatus(provider: .codex, availability: .notInstalled, message: nil)
        #expect(en.statusTitle(codexNotInstalled) == "Not installed")
        #expect(en.statusInstruction(codexNotInstalled) == "Install the Codex CLI and make sure `codex` is on PATH.")
    }

    // MARK: - StatusItemFormatter.text

    @Test func formatterBasicText() {
        let snap = makeSnapshot(.claude, fiveHourUsed: 12.4, weeklyUsed: 76.6)
        #expect(StatusItemFormatter.text(prefix: "Cl", snapshot: snap) == "Cl · 5h 12% · 7d 77%")
    }

    @Test func formatterPaceSuffix() {
        let snap = makeSnapshot(
            .claude,
            weeklyUsed: 40,
            weeklyReset: Date().addingTimeInterval(3.5 * 86_400)
        )
        let text = StatusItemFormatter.text(prefix: "Cl", snapshot: snap)
        #expect(text.contains("p +") || text.contains("p −") || text.contains("p -"))
    }

    @Test func formatterMonthlyLabel() {
        let snap = ProviderSnapshot(
            provider: .zai,
            fiveHour: makeWindow(.fiveHour, used: 10),
            weekly: makeWindow(.monthly, used: 50),
            modelWindows: [],
            detail: nil
        )
        let content = StatusItemFormatter.content(name: "Z", snapshot: snap)
        #expect(content.metrics.contains { $0.label == "1m" })
        #expect(StatusItemFormatter.text(prefix: "Z", snapshot: snap).contains("1m"))
    }

    @Test func formatterDropsErroredLongWindow() {
        let snap = makeSnapshot(.claude, fiveHourUsed: 10, weeklyMessage: "No weekly limit returned.")
        let text = StatusItemFormatter.text(prefix: "Cl", snapshot: snap)
        #expect(text.contains("5h"))
        #expect(!text.contains("7d"))
    }

    @Test func formatterModelWindowsFirst() {
        let model = ModelUsageWindow(
            modelName: "ClaudeSonnet",
            window: makeWindow(.modelWeekly, used: 30),
            isActive: false
        )
        let snap = makeSnapshot(.claude, fiveHourUsed: 12, weeklyUsed: 77, modelWindows: [model])
        let content = StatusItemFormatter.content(name: "Cl", snapshot: snap)

        let first = try! #require(content.metrics.first)
        #expect(first.isModelScoped == true)
        #expect(first.label == "ClaudeS")

        let text = StatusItemFormatter.text(prefix: "Cl", snapshot: snap)
        let modelIndex = try! #require(text.range(of: "ClaudeS"))
        let fiveHourIndex = try! #require(text.range(of: "5h"))
        #expect(modelIndex.lowerBound < fiveHourIndex.lowerBound)
    }

    // MARK: - StatusItemLabelView.resolvedFallbackText

    @Test func resolvedFallbackText() {
        #expect(
            StatusItemLabelView.resolvedFallbackText(claudeText: nil, codexText: "  ", geminiText: nil, zaiText: nil)
                == StatusItemLabelView.defaultFallbackText
        )
        #expect(StatusItemLabelView.defaultFallbackText == "Token Watch")
        #expect(
            StatusItemLabelView.resolvedFallbackText(claudeText: "Cl", codexText: nil, geminiText: nil, zaiText: nil)
                == nil
        )
    }
}
