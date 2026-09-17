import SwiftUI

struct StatusItemLabelView: View {
    nonisolated static let defaultFallbackText = "Token Watch"

    let claudeUsage: StatusItemProviderUsage?
    let codexUsage: StatusItemProviderUsage?
    let geminiUsage: StatusItemProviderUsage?
    let zaiUsage: StatusItemProviderUsage?
    let museUsage: StatusItemProviderUsage?
    let alicloudUsage: StatusItemProviderUsage?

    nonisolated static func resolvedFallbackText(
        claudeText: String?,
        codexText: String?,
        geminiText: String? = nil,
        zaiText: String? = nil,
        museText: String? = nil,
        alicloudText: String? = nil
    ) -> String? {
        let allNilOrBlank = [claudeText, codexText, geminiText, zaiText, museText, alicloudText].allSatisfy { text in
            guard let text = text else { return true }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return allNilOrBlank ? defaultFallbackText : nil
    }

    var body: some View {
        HStack(spacing: 4) {
            if let claude = claudeUsage {
                usagePill(for: claude, color: AppTheme.claudeAccent)
            }
            if let codex = codexUsage {
                usagePill(for: codex, color: AppTheme.codexAccent)
            }
            if let gemini = geminiUsage {
                usagePill(for: gemini, color: AppTheme.geminiAccent)
            }
            if let zai = zaiUsage {
                usagePill(for: zai, color: AppTheme.zaiAccent)
            }
            if let muse = museUsage {
                usagePill(for: muse, color: AppTheme.museAccent)
            }
            if let alicloud = alicloudUsage {
                usagePill(for: alicloud, color: AppTheme.alicloudAccent)
            }

            if claudeUsage == nil && codexUsage == nil && geminiUsage == nil && zaiUsage == nil && museUsage == nil && alicloudUsage == nil {
                fallbackPill
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
    }

    private func usagePill(for usage: StatusItemProviderUsage, color: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(usage.metrics, id: \.label) { metric in
                standardMetric(metric)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Capsule().fill(color))
    }

    private func standardMetric(_ metric: StatusItemMetric) -> some View {
        HStack(spacing: 1) {
            if !metric.label.isEmpty {
                Text(metric.label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
            }
            Text(metric.value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .fixedSize()
        }
    }

    private var fallbackPill: some View {
        Text(Self.defaultFallbackText)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(Capsule().fill(Color.gray.opacity(0.6)))
    }
}
