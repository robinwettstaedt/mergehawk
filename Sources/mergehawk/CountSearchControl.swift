import AppKit
import SwiftUI

struct CountSearchPresentation {
    static func countLabel(for count: Int, singular: String, plural: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural)"
    }
}

struct ExpandableSearchState: Equatable {
    var isExpanded = false
    var query = ""

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasActiveQuery: Bool {
        !trimmedQuery.isEmpty
    }

    mutating func expand() {
        isExpanded = true
    }

    mutating func blur() {
        if !hasActiveQuery {
            isExpanded = false
        }
    }

    mutating func handleEscape() {
        if hasActiveQuery {
            query = ""
        } else {
            isExpanded = false
        }
    }
}

struct CountSearchControl: View {
    @Binding var searchState: ExpandableSearchState
    let countLabel: String
    let placeholder: String
    let help: String
    var isAlwaysExpanded = false
    var showsInlineCount = true
    var expandedWidth: CGFloat?
    @State private var searchFieldFocused = false
    @State private var searchFocusRequest = 0

    var body: some View {
        HStack(spacing: 7) {
            if isSearchExpanded {
                expandedSearchControls
            } else {
                MenuControlButton(
                    symbolName: "magnifyingglass",
                    title: countLabel,
                    isOpen: false,
                    help: help
                ) {
                    searchState.expand()
                    DispatchQueue.main.async {
                        searchFocusRequest += 1
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isSearchExpanded)
        .onExitCommand {
            searchState.handleEscape()
            if !isSearchExpanded {
                searchFieldFocused = false
            }
        }
    }

    private var isSearchExpanded: Bool {
        isAlwaysExpanded || searchState.isExpanded
    }

    private var expandedSearchControls: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TransparentSearchTextField(
                text: $searchState.query,
                placeholder: placeholder,
                isFocused: $searchFieldFocused,
                focusRequest: searchFocusRequest
            ) {
                if !isAlwaysExpanded {
                    searchState.blur()
                }
            }
            .accessibilityLabel(help)
            .frame(height: 16)
            .onChange(of: searchState.isExpanded) { _, isExpanded in
                if !isExpanded && !isAlwaysExpanded {
                    searchFieldFocused = false
                }
            }
            if searchState.hasActiveQuery, showsInlineCount {
                Text(countLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if searchState.hasActiveQuery {
                clearSearchButton
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(width: expandedWidth)
        .frame(maxWidth: expandedWidth == nil ? .infinity : nil)
        .background(.ultraThinMaterial)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            searchState.expand()
            searchFocusRequest += 1
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    searchFieldFocused ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor).opacity(0.55),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var clearSearchButton: some View {
        Button {
            searchState.query = ""
            searchState.expand()
            DispatchQueue.main.async {
                searchFieldFocused = false
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Clear search")
        .accessibilityLabel("Clear search")
    }
}

private struct TransparentSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let focusRequest: Int
    let onBlur: () -> Void

    init(
        text: Binding<String>,
        placeholder: String,
        isFocused: Binding<Bool>,
        focusRequest: Int,
        onBlur: @escaping () -> Void
    ) {
        _text = text
        _isFocused = isFocused
        self.placeholder = placeholder
        self.focusRequest = focusRequest
        self.onBlur = onBlur
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = SearchTextField()
        field.delegate = context.coordinator
        Self.configure(field)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        Self.configure(field)
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        context.coordinator.onBlur = onBlur
        let shouldRequestFocus = context.coordinator.focusRequest != focusRequest
        context.coordinator.focusRequest = focusRequest

        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }

        if shouldRequestFocus || (isFocused && field.window?.firstResponder !== field.currentEditor()) {
            Self.focus(field)
        } else if !isFocused, field.window?.firstResponder === field.currentEditor() {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(nil)
            }
        } else {
            Self.configureEditor(for: field)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onBlur: onBlur)
    }

    private static func configure(_ field: NSTextField) {
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.clear.cgColor
        if let cell = field.cell as? NSTextFieldCell {
            cell.drawsBackground = false
            cell.backgroundColor = .clear
            cell.focusRingType = .none
        }
    }

    private static func focus(_ field: NSTextField, attemptsRemaining: Int = 3) {
        DispatchQueue.main.async {
            guard field.window != nil else {
                if attemptsRemaining > 0 {
                    focus(field, attemptsRemaining: attemptsRemaining - 1)
                }
                return
            }
            field.window?.makeFirstResponder(field)
            configureEditor(for: field)
        }
    }

    private static func configureEditor(for field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else {
            return
        }
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.insertionPointColor = .controlAccentColor
        editor.enclosingScrollView?.drawsBackground = false
        editor.superview?.wantsLayer = true
        editor.superview?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private final class SearchTextField: NSTextField {
        override func becomeFirstResponder() -> Bool {
            let becameFirstResponder = super.becomeFirstResponder()
            if becameFirstResponder {
                TransparentSearchTextField.configure(self)
                DispatchQueue.main.async {
                    TransparentSearchTextField.configureEditor(for: self)
                }
            }
            return becameFirstResponder
        }

        override func draw(_ dirtyRect: NSRect) {
            TransparentSearchTextField.configure(self)
            super.draw(dirtyRect)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var onBlur: () -> Void
        var focusRequest = 0

        init(text: Binding<String>, isFocused: Binding<Bool>, onBlur: @escaping () -> Void) {
            self.text = text
            self.isFocused = isFocused
            self.onBlur = onBlur
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                TransparentSearchTextField.configureEditor(for: field)
                DispatchQueue.main.async {
                    TransparentSearchTextField.configureEditor(for: field)
                }
            }
            isFocused.wrappedValue = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
            onBlur()
        }
    }
}
