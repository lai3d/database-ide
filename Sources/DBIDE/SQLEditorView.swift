import AppKit
import DBIDECore
import SwiftUI

@MainActor
enum EditorTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let gridFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func color(for kind: SQLTokenKind) -> NSColor {
        switch kind {
        case .keyword: .systemBlue
        case .string: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil ? #colorLiteral(red: 0.42, green: 0.75, blue: 0.40, alpha: 1) : #colorLiteral(red: 0.10, green: 0.50, blue: 0.10, alpha: 1) }
        case .number: .systemTeal
        case .comment: .secondaryLabelColor
        case .quotedIdentifier: .systemPurple
        case .parameter: .systemOrange
        case .identifier, .op, .semicolon: .textColor
        }
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }
}

/// Synchronous completion source; returns candidates for the word before the caret.
typealias CompletionProvider = @MainActor (_ text: String, _ wordRange: NSRange) -> [String]

struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var dialect: SQLDialect
    var isEditable = true
    var executingRange: NSRange? = nil
    var errorRange: NSRange? = nil
    var onSelectionChange: ((NSRange) -> Void)? = nil
    var completions: CompletionProvider? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SQLTextView(usingTextLayoutManager: false)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let big = CGFloat.greatestFiniteMagnitude
        textView.minSize = .zero
        textView.maxSize = NSSize(width: big, height: big)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: big, height: big)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = EditorTheme.font
        textView.typingAttributes = EditorTheme.baseAttributes
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.backgroundColor = .textBackgroundColor
        textView.isEditable = isEditable
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator

        scrollView.documentView = textView
        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let textView = c.textView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            // External change (history insert, restore): keep undo coherent.
            let sel = textView.selectedRange()
            if textView.shouldChangeText(in: NSRange(location: 0, length: (textView.string as NSString).length), replacementString: text) {
                textView.string = text
                textView.didChangeText()
            }
            let len = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
            c.highlight()
        } else if c.lastDialect != dialect {
            c.highlight()
        }
        c.updateMarkers()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var textView: SQLTextView?
        var lastDialect: SQLDialect?
        private var shownExecuting: NSRange?
        private var shownError: NSRange?

        init(_ parent: SQLEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            highlight()
            shownError = nil
            updateMarkers(force: true)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.onSelectionChange?(tv.selectedRange())
        }

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            lastDialect = parent.dialect
            let text = tv.string
            let full = NSRange(location: 0, length: (text as NSString).length)
            storage.beginEditing()
            storage.setAttributes(EditorTheme.baseAttributes, range: full)
            for token in SQLLexer.tokenize(text, dialect: parent.dialect) where NSMaxRange(token.range) <= full.length {
                let color = EditorTheme.color(for: token.kind)
                if color != .textColor { storage.addAttribute(.foregroundColor, value: color, range: token.range) }
                if token.kind == .comment {
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(EditorTheme.font, toHaveTrait: .italicFontMask), range: token.range)
                }
                if token.kind == .keyword {
                    storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), range: token.range)
                }
            }
            storage.endEditing()
        }

        /// Executing statement background and error underline, as temporary attributes.
        func updateMarkers(force: Bool = false) {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            guard force || shownExecuting != parent.executingRange || shownError != parent.errorRange else { return }
            let len = (tv.string as NSString).length
            let full = NSRange(location: 0, length: len)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
            shownExecuting = parent.executingRange
            shownError = parent.errorRange
            if let r = parent.executingRange, NSMaxRange(r) <= len {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.18), forCharacterRange: r)
            }
            if var r = parent.errorRange, r.location <= len {
                if r.length == 1 {
                    // Underline the token at the error position.
                    let s = tv.string as NSString
                    var end = r.location
                    while end < s.length, let u = UnicodeScalar(s.character(at: end)),
                        CharacterSet.alphanumerics.contains(u) || u == "_" { end += 1 }
                    r.length = max(1, end - r.location)
                }
                r.length = min(r.length, len - r.location)
                lm.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue, forCharacterRange: r)
                lm.addTemporaryAttribute(.underlineColor, value: NSColor.systemRed, forCharacterRange: r)
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.12), forCharacterRange: r)
            }
        }

        func textView(
            _ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            index?.pointee = 0
            return parent.completions?(textView.string, charRange) ?? []
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                // Keep the current line's indentation.
                let s = textView.string as NSString
                let caret = textView.selectedRange().location
                let line = s.lineRange(for: NSRange(location: min(caret, s.length), length: 0))
                var indent = ""
                var i = line.location
                while i < caret, i < s.length, let u = UnicodeScalar(s.character(at: i)), u == " " || u == "\t" {
                    indent.append(Character(u))
                    i += 1
                }
                textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
                return true
            }
            if selector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText("    ", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }
    }
}

final class SQLTextView: NSTextView {
    weak var coordinator: SQLEditorView.Coordinator?

    override var rangeForUserCompletion: NSRange {
        let s = string as NSString
        let caret = selectedRange().location
        var start = caret
        while start > 0, let u = UnicodeScalar(s.character(at: start - 1)),
            CharacterSet.alphanumerics.contains(u) || u == "_" || u == "$"
        {
            start -= 1
        }
        return NSRange(location: start, length: caret - start)
    }

    override func keyDown(with event: NSEvent) {
        // ⌃Space triggers completion, like JetBrains IDEs.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, event.charactersIgnoringModifiers == " " {
            complete(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if (string as? String) == "." {
            DispatchQueue.main.async { [weak self] in self?.complete(nil) }
        }
    }

    /// ⌘/ toggles `-- ` line comments on the selected lines.
    @objc func toggleComment(_ sender: Any?) {
        let s = string as NSString
        let lines = s.lineRange(for: selectedRange())
        let block = s.substring(with: lines)
        var parts = block.components(separatedBy: "\n")
        let hasTrailingNewline = block.hasSuffix("\n")
        if hasTrailingNewline { parts.removeLast() }
        let allCommented = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let newParts = parts.map { line -> String in
            if allCommented {
                guard let r = line.range(of: "--") else { return line }
                var l = line
                l.removeSubrange(r)
                if l[r.lowerBound...].hasPrefix(" ") { l.remove(at: r.lowerBound) }
                return l
            }
            return line.trimmingCharacters(in: .whitespaces).isEmpty ? line : "-- " + line
        }
        let replacement = newParts.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        if shouldChangeText(in: lines, replacementString: replacement) {
            textStorage?.replaceCharacters(in: lines, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: lines.location, length: (replacement as NSString).length))
        }
    }
}

/// Line numbers in the gutter (TextKit 1).
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func refresh() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let s = tv.string as NSString
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: container)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Line number of the first visible character.
        var line = 1
        var i = 0
        while i < chars.location {
            let r = s.lineRange(for: NSRange(location: i, length: 0))
            if NSMaxRange(r) > chars.location { break }
            line += 1
            i = NSMaxRange(r)
        }
        let inset = tv.textContainerInset.height
        var index = chars.location
        func draw(_ y: CGFloat, _ height: CGFloat) {
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            let point = NSPoint(x: ruleThickness - size.width - 6, y: y + inset - visible.minY + (height - size.height) / 2)
            label.draw(at: convert(point, from: self), withAttributes: attrs)
        }
        while index < NSMaxRange(chars) {
            let lineRange = s.lineRange(for: NSRange(location: index, length: 0))
            let glyph = lm.glyphIndexForCharacter(at: lineRange.location)
            let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(rect.minY, rect.height)
            line += 1
            index = NSMaxRange(lineRange)
        }
        if s.length == 0 || s.hasSuffix("\n"), NSMaxRange(chars) == s.length {
            let rect = lm.extraLineFragmentRect
            if rect.height > 0 { draw(rect.minY, rect.height) }
        }
    }
}
