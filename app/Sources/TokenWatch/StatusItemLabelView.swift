import SwiftUI

struct StatusItemLabelView: View {
    nonisolated static let defaultFallbackText = "Token Watch"

    let claudeUsage: StatusItemProviderUsage?
    let codexUsage: StatusItemProviderUsage?
    let geminiUsage: StatusItemProviderUsage?
    let zaiUsage: StatusItemProviderUsage?

    nonisolated static func resolvedFallbackText(
        claudeText: String?,
        codexText: String?,
        geminiText: String? = nil,
        zaiText: String? = nil
    ) -> String? {
        let allNilOrBlank = [claudeText, codexText, geminiText, zaiText].allSatisfy { text in
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

            if claudeUsage == nil && codexUsage == nil && geminiUsage == nil && zaiUsage == nil {
                fallbackPill
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
    }

    private func usagePill(for usage: StatusItemProviderUsage, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(height: 16)
            .padding(.horizontal, 6)
            .overlay {
                HStack(spacing: 6) {
                    ForEach(usage.metrics, id: \.label) { metric in
                        if metric.isModelScoped {
                            modelScopedMetric(metric)
                        } else {
                            standardMetric(metric)
                        }
                    }
                }
            }
    }

    private func standardMetric(_ metric: StatusItemMetric) -> some View {
        HStack(spacing: 1) {
            Text(metric.label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
            Text(metric.value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .fixedSize()
        }
    }

    private func modelScopedMetric(_ metric: StatusItemMetric) -> some View {
        HStack(spacing: 1) {
            Text(metric.label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
            Text(metric.value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .fixedSize()
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(.white.opacity(0.25))
        )
    }

    private var fallbackPill: some View {
        Capsule()
            .fill(Color.gray.opacity(0.6))
            .frame(height: 16)
            .padding(.horizontal, 6)
            .overlay {
                Text(Self.defaultFallbackText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .fixedSize()
            }
    }
}
