import AppKit
import DBIDECore
import SwiftUI

@MainActor
enum EditorTheme {
    static var font: NSFont { NSFont.monospacedSystemFont(ofSize: Preferences.fontSize, weight: .regular) }
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

/// Synchronous completion source for the caret position.
typealias Completer = @MainActor (_ text: String, _ caret: Int) -> SQLCompletionResult

struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var dialect: SQLDialect
    var isEditable = true
    var executingRange: NSRange? = nil
    var errorRange: NSRange? = nil
    var onSelectionChange: ((NSRange) -> Void)? = nil
    var completer: Completer? = nil
    @AppStorage(Preferences.fontSizeKey) private var fontSize = 13.0
    /// Bumped when more catalog data arrived; an open popup refreshes.
    var completionVersion = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SQLTextView(usingTextLayoutManager: false)
        let scrollView = RulerScrollView()
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
            if !textView.isEditable {
                // Read-only views (DDL, JSON results) refuse shouldChangeText; just replace and show the start.
                textView.string = text
                scrollView.contentView.scroll(to: NSPoint(x: -scrollView.contentView.contentInsets.left, y: -scrollView.contentView.contentInsets.top))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else if textView.shouldChangeText(in: NSRange(location: 0, length: (textView.string as NSString).length), replacementString: text) {
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
        if c.lastFontSize != fontSize {
            c.lastFontSize = fontSize
            textView.font = EditorTheme.font
            textView.typingAttributes = EditorTheme.baseAttributes
            c.highlight()
            scrollView.verticalRulerView?.needsDisplay = true
        }
        if c.lastCompletionVersion != completionVersion {
            c.lastCompletionVersion = completionVersion
            if c.popup.isVisible { c.updateCompletion(explicit: false) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var textView: SQLTextView?
        var lastDialect: SQLDialect?
        private var shownExecuting: NSRange?
        private var shownError: NSRange?
        let popup = CompletionPopup()
        var lastCompletionVersion = 0
        var lastFontSize = Preferences.fontSize
        /// Set by the text view when the user typed a word character or `.`.
        var triggerPending = false
        var suppressTrigger = false
        private var replaceRange: NSRange?
        private var inTextChange = false

        init(_ parent: SQLEditorView) {
            self.parent = parent
            super.init()
            popup.onAccept = { [weak self] in self?.accept($0) }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            highlight()
            shownError = nil
            updateMarkers(force: true)
            if (triggerPending && Preferences.autoComplete) || popup.isVisible {
                inTextChange = true
                updateCompletion(explicit: false)
                inTextChange = false
            }
            triggerPending = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.onSelectionChange?(tv.selectedRange())
            // Caret moved by click / arrows (not typing): drop the popup if it left the word.
            if popup.isVisible, !inTextChange, let r = replaceRange {
                let sel = tv.selectedRange()
                if sel.length > 0 || sel.location < r.location || sel.location > NSMaxRange(r) + 1 { popup.hide() }
            }
        }

        // MARK: Completion

        func updateCompletion(explicit: Bool) {
            guard let tv = textView, let window = tv.window, let completer = parent.completer, tv.isEditable else { return }
            let sel = tv.selectedRange()
            guard sel.length == 0 else { return popup.hide() }
            let result = completer(tv.string, sel.location)
            guard !result.items.isEmpty else {
                popup.hide()
                if explicit { NSSound.beep() }
                return
            }
            replaceRange = result.replaceRange
            let anchor = tv.firstRect(forCharacterRange: NSRange(location: result.replaceRange.location, length: 0), actualRange: nil)
            popup.show(result.items, below: anchor, in: window)
        }

        func accept(_ item: SQLCompletionItem) {
            guard let tv = textView, let r = replaceRange, NSMaxRange(r) <= (tv.string as NSString).length else { return }
            popup.hide()
            // The word may have grown since the popup was computed.
            let caret = tv.selectedRange().location
            let range = NSRange(location: r.location, length: max(r.length, caret - r.location))
            suppressTrigger = true
            tv.insertText(item.insertText, replacementRange: range)
            suppressTrigger = false
        }

        /// Keys the popup handles while visible. Returns true when consumed.
        func handleKey(_ event: NSEvent) -> Bool {
            guard popup.isVisible else { return false }
            switch event.keyCode {
            case 125: popup.moveSelection(by: 1)
            case 126: popup.moveSelection(by: -1)
            case 121: popup.moveSelection(by: CompletionPopup.visibleRows)
            case 116: popup.moveSelection(by: -CompletionPopup.visibleRows)
            case 36, 76, 48:  // return, enter, tab
                if let item = popup.selectedItem { accept(item) } else { popup.hide() }
            case 53: popup.hide()  // escape
            default: return false
            }
            return true
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
                    storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: Preferences.fontSize, weight: .semibold), range: token.range)
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

    override func keyDown(with event: NSEvent) {
        if coordinator?.handleKey(event) == true { return }
        // ⌃Space triggers completion, like JetBrains IDEs.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, event.charactersIgnoringModifiers == " " {
            coordinator?.updateCompletion(explicit: true)
            return
        }
        super.keyDown(with: event)
    }

    /// Esc (NSTextView's default completion key) opens our popup.
    override func complete(_ sender: Any?) {
        coordinator?.updateCompletion(explicit: true)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let c = coordinator, !c.suppressTrigger, let s = string as? String, !s.isEmpty,
            s.utf16.allSatisfy({ SQLCompletionWordChar.isWordChar($0) || $0 == 46 })
        {
            c.triggerPending = true
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func resignFirstResponder() -> Bool {
        coordinator?.popup.hide()
        return super.resignFirstResponder()
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

/// On macOS 14+ rulers overlay the content: the clip view gets a left inset equal to the
/// ruler width, so the true left edge is x = -inset. The inset can arrive after the text is
/// loaded, leaving the view at x = 0 with the first characters hidden under the gutter.
/// Re-anchor to the left edge whenever the inset changes and the view was at the old edge.
/// (Same fix as lai3d/esp32-ide 2f59ea3.)
final class RulerScrollView: NSScrollView {
    private var lastInset: CGFloat = 0

    override func tile() {
        let wasAtLeftEdge = contentView.bounds.origin.x <= -lastInset + 0.5
        super.tile()
        let inset = contentView.contentInsets.left
        guard inset != lastInset else { return }
        lastInset = inset
        if wasAtLeftEdge {
            contentView.scroll(to: NSPoint(x: -inset, y: contentView.bounds.origin.y))
            reflectScrolledClipView(contentView)
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

enum SQLCompletionWordChar {
    static func isWordChar(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 128
    }
}
