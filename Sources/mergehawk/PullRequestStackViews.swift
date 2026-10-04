import mergehawkcore
import SwiftUI

/// The chip on a requested stack card: "‹position› of ‹size›" and "+N" other review requests in the stack.
struct StackChipPresentation: Equatable {
    static let stackSymbolName = "square.stack"

    let positionText: String
    /// "+N" when other open members also request the viewer's review; nil when N is 0.
    let additionalRequestsText: String?
    let chevronSymbolName: String
    let tooltip: String

    var accessibilityLabel: String { tooltip }

    init(group: StackGroup, isExpanded: Bool) {
        positionText = "\(group.representativePosition) of \(group.stack.size)"
        let additional = group.additionalRequestCount
        additionalRequestsText = additional > 0 ? "+\(additional)" : nil
        chevronSymbolName = isExpanded ? "chevron.down" : "chevron.right"
        var parts = ["Stack", positionText]
        if additional > 0 {
            parts.append("\(additional) more review \(additional == 1 ? "request" : "requests")")
        }
        let excluded = group.filterExcludedRequestCount
        if excluded > 0 {
            parts.append("\(excluded) outside the current filter")
        }
        tooltip = parts.joined(separator: " · ")
    }
}

struct StackChip: View {
    let presentation: StackChipPresentation
    let toggle: () -> Void

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: metrics.prRow.stackChipSpacing) {
                Image(systemName: StackChipPresentation.stackSymbolName)
                    .font(metrics.type.stackChipSymbol.font)
                Text(presentation.positionText)
                if let additional = presentation.additionalRequestsText {
                    Text(additional)
                        .foregroundStyle(Color.accentColor)
                }
                Image(systemName: presentation.chevronSymbolName)
                    .font(metrics.type.stackChipSymbol.font)
            }
            .font(metrics.type.cardMetadata.font)
            .lineLimit(1)
            .padding(.horizontal, metrics.prRow.stackChipHorizontalPadding)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .menuTooltip(presentation.tooltip, providesAccessibilityHint: false)
        .accessibilityLabel(presentation.accessibilityLabel)
        // The symbols are slightly taller than the metadata text; a zero layout height keeps the card height.
        .frame(height: 0)
    }
}
