import AppKit

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var observers: [NSObjectProtocol] = []

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers = [
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in self?.needsDisplay = true },
            NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in self?.needsDisplay = true },
            NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in self?.needsDisplay = true },
        ]
    }

    /// Line number containing the insertion point (1-based)
    private var currentLineNumber: Int {
        guard let textView else { return 1 }
        let source = textView.string as NSString
        let location = min(textView.selectedRange().location, source.length)
        var line = 1
        var index = 0
        while index < location {
            var nextLineStart = 0
            source.getLineStart(nil, end: &nextLineStart, contentsEnd: nil, for: NSRange(location: index, length: 0))
            guard nextLineStart > index, nextLineStart <= location else { break }
            index = nextLineStart
            line += 1
        }
        return line
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView else {
            return
        }

        // VS Code-style gutter: same background as the editor, dim numbers,
        // the current line's number rendered brighter.
        (textView.backgroundColor).setFill()
        bounds.fill()

        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let source = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let currentLineAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let currentLine = currentLineNumber

        if source.length == 0 {
            let number = "1" as NSString
            let size = number.size(withAttributes: currentLineAttributes)
            number.draw(
                at: NSPoint(
                    x: ruleThickness - size.width - 10,
                    y: textView.textContainerOrigin.y
                ),
                withAttributes: currentLineAttributes
            )
            return
        }

        var lineStart = 0
        var lineNumber = 1
        while lineStart < characterRange.location, lineStart < source.length {
            var nextLineStart = 0
            source.getLineStart(nil, end: &nextLineStart, contentsEnd: nil, for: NSRange(location: lineStart, length: 0))
            guard nextLineStart > lineStart else { break }
            lineStart = nextLineStart
            lineNumber += 1
        }

        let visibleEnd = min(NSMaxRange(characterRange) + 1, source.length + 1)
        repeat {
            let characterIndex = min(lineStart, source.length - 1)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = fragment.minY + textView.textContainerOrigin.y - visibleRect.minY
            let number = "\(lineNumber)" as NSString
            let numberAttributes = lineNumber == currentLine ? currentLineAttributes : attributes
            let size = number.size(withAttributes: numberAttributes)
            number.draw(
                at: NSPoint(x: ruleThickness - size.width - 10, y: y + (fragment.height - size.height) / 2),
                withAttributes: numberAttributes
            )

            guard lineStart < source.length else { break }
            var nextLineStart = 0
            source.getLineStart(nil, end: &nextLineStart, contentsEnd: nil, for: NSRange(location: lineStart, length: 0))
            guard nextLineStart > lineStart else { break }
            lineStart = nextLineStart
            lineNumber += 1
        } while lineStart < visibleEnd
    }
}
