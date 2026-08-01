import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    let wrapsLines: Bool

    static func clampedSelectionRanges(_ ranges: [NSValue], textLength: Int) -> [NSValue] {
        let safeLength = max(textLength, 0)
        guard !ranges.isEmpty else {
            return [NSValue(range: NSRange(location: 0, length: 0))]
        }
        return ranges.map { value in
            let range = value.rangeValue
            let location = min(range.location, safeLength)
            let length = min(range.length, safeLength - location)
            return NSValue(range: NSRange(location: location, length: length))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, language: language)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrapsLines
        scrollView.autohidesScrollers = true

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.typingAttributes = context.coordinator.baseAttributes
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)

        scrollView.documentView = textView
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.applyLayout(wrapsLines: wrapsLines, in: scrollView)
        context.coordinator.scheduleHighlighting(immediately: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.textBinding = $text
        context.coordinator.language = language
        context.coordinator.textView = textView
        context.coordinator.applyLayout(wrapsLines: wrapsLines, in: scrollView)

        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = Self.clampedSelectionRanges(selection, textLength: text.utf16.count)
            context.coordinator.scheduleHighlighting(immediately: true)
        } else if context.coordinator.highlightedLanguage != language {
            context.coordinator.scheduleHighlighting(immediately: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var textBinding: Binding<String>
        var language: CodeLanguage
        weak var textView: NSTextView?
        private var highlightTask: Task<Void, Never>?
        private(set) var highlightedLanguage: CodeLanguage?

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]

        init(text: Binding<String>, language: CodeLanguage) {
            textBinding = text
            self.language = language
        }

        deinit {
            highlightTask?.cancel()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            textBinding.wrappedValue = textView.string
            scheduleHighlighting()
        }

        func applyLayout(wrapsLines: Bool, in scrollView: NSScrollView) {
            guard let textView, let textContainer = textView.textContainer else { return }
            scrollView.hasHorizontalScroller = !wrapsLines
            textView.isHorizontallyResizable = !wrapsLines
            textView.isVerticallyResizable = true
            textView.autoresizingMask = wrapsLines ? [.width] : []
            textContainer.widthTracksTextView = wrapsLines
            textContainer.containerSize = NSSize(
                width: wrapsLines ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            if wrapsLines {
                textView.frame.size.width = scrollView.contentSize.width
            }
        }

        private func applyHighlighting(
            tokens: [SyntaxToken],
            source: String,
            language: CodeLanguage
        ) {
            guard let textView,
                  textView.string == source,
                  self.language == language,
                  let storage = textView.textStorage else {
                return
            }
            let selectedRanges = textView.selectedRanges
            let fullRange = NSRange(location: 0, length: source.utf16.count)

            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: fullRange)
            for token in tokens {
                storage.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
                if token.kind == .keyword || token.kind == .heading {
                    storage.addAttribute(
                        .font,
                        value: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                        range: token.range
                    )
                }
            }
            storage.endEditing()

            textView.typingAttributes = baseAttributes
            textView.selectedRanges = selectedRanges
            highlightedLanguage = language
            scrollViewRuler?.needsDisplay = true
        }

        private var scrollViewRuler: NSRulerView? {
            textView?.enclosingScrollView?.verticalRulerView
        }

        func scheduleHighlighting(immediately: Bool = false) {
            highlightTask?.cancel()
            guard let textView else { return }
            let source = textView.string
            let language = language
            highlightTask = Task { @MainActor [weak self] in
                if !immediately {
                    try? await Task.sleep(for: .milliseconds(60))
                }
                guard !Task.isCancelled else { return }
                let tokens = await Task.detached(priority: .userInitiated) {
                    SyntaxHighlighter.tokens(in: source, language: language)
                }.value
                guard !Task.isCancelled else { return }
                self?.applyHighlighting(tokens: tokens, source: source, language: language)
            }
        }
    }
}

private extension SyntaxToken.Kind {
    /// VS Code Light+ / Dark+ token palette, adapting to the system appearance.
    var color: NSColor {
        switch self {
        case .comment: .dynamic(light: 0x008000, dark: 0x6A9955)
        case .string: .dynamic(light: 0xA31515, dark: 0xCE9178)
        case .number: .dynamic(light: 0x098658, dark: 0xB5CEA8)
        case .keyword: .dynamic(light: 0x0000FF, dark: 0x569CD6)
        case .type: .dynamic(light: 0x267F99, dark: 0x4EC9B0)
        case .function: .dynamic(light: 0x795E26, dark: 0xDCDCAA)
        case .property: .dynamic(light: 0x001080, dark: 0x9CDCFE)
        case .tag: .dynamic(light: 0x800000, dark: 0x569CD6)
        case .heading: .dynamic(light: 0x0000FF, dark: 0x569CD6)
        }
    }
}

private extension NSColor {
    static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
