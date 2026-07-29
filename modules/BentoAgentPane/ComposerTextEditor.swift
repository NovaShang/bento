import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
// MARK: - Composer text editor (macOS)

/// A plain-text composer input backed by NSTextView. Grows with content up to
/// `maxHeight`, then scrolls internally. Unlike SwiftUI's
/// `TextField(axis: .vertical)` — which re-lays out the entire string on every
/// SwiftUI render and hangs on large pastes — NSTextView owns its text storage
/// and lays out once per edit, so big drafts stay smooth. Return submits;
/// Shift+Return inserts a newline; ↑/↓/⇥/⎋ are forwarded so the slash-command
/// panel and turn-cancel keep working. Image ⌘V is caught upstream by the pane
/// surface's event monitor, so it never reaches here as pasted text.
struct AcpComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    /// True while an IME composition (marked/pre-edit text) is on screen. That
    /// text lives in the input context, not in `string`, so `textDidChange`
    /// never fires for it — the host watches this to hide the placeholder that
    /// would otherwise overlap the composing glyphs.
    @Binding var isComposing: Bool
    var isEditable: Bool
    var maxHeight: CGFloat
    /// Bumped by the host to pull first-responder into the field.
    var focusToken: Int
    /// UTF-16 length of the leading "/command" token to accent-highlight (0 =
    /// none).
    var highlightLength: Int
    var onReturn: () -> Void
    var onArrow: (Int) -> Bool
    var onTab: () -> Bool
    var onEscape: () -> Bool

    private static let font = NSFont.systemFont(ofSize: 13.5)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = ComposingTextView()
        textView.delegate = context.coordinator
        textView.onComposingChange = { [weak coordinator = context.coordinator] composing in
            coordinator?.setComposing(composing)
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        scroll.documentView = textView
        context.coordinator.textView = textView
        // Initial layout pass so the field opens at the right height.
        DispatchQueue.main.async { context.coordinator.recomputeHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // Gate the layout-touching work on real changes: this runs on EVERY
        // SwiftUI render of the composer (any chat-model or session publish,
        // including each streaming flush), and ensureLayout/usedRect walk the
        // whole draft — unconditional recompute was constant O(draft) work.
        // Never reconcile `string` while an IME composition is live: the draft
        // is still empty (marked text isn't committed yet), so writing it back
        // would wipe the pre-edit text and break composition.
        var textChanged = false
        if !textView.hasMarkedText() && textView.string != text {
            textView.string = text; textChanged = true
        }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        if textChanged || context.coordinator.lastHighlightLength != highlightLength {
            context.coordinator.lastHighlightLength = highlightLength
            context.coordinator.applyHighlight()
        }
        // A width change (pane resize, sidebar toggle) re-wraps the draft.
        let width = scroll.contentSize.width
        if textChanged || abs(width - context.coordinator.lastWidth) > 0.5 {
            context.coordinator.lastWidth = width
            context.coordinator.recomputeHeight()
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AcpComposerTextEditor
        weak var textView: NSTextView?
        var lastFocusToken: Int
        var lastWidth: CGFloat = 0
        var lastHighlightLength = 0

        init(_ parent: AcpComposerTextEditor) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyHighlight()
            recomputeHeight()
        }

        /// Mirror the text view's IME composition state up to SwiftUI. Deferred
        /// so we don't mutate observable state inside the AppKit input path
        /// (which would re-enter this representable's update).
        func setComposing(_ composing: Bool) {
            guard parent.isComposing != composing else { return }
            DispatchQueue.main.async { self.parent.isComposing = composing }
        }

        /// Paint (or clear) the accent background behind the leading command
        /// token via a temporary attribute — doesn't touch text storage or
        /// undo, and follows the glyphs through wrapping and scrolling.
        func applyHighlight() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            let length = min(parent.highlightLength, full.length)
            guard length > 0 else { return }
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.18),
                forCharacterRange: NSRange(location: 0, length: length))
        }

        /// Report the content height (clamped to maxHeight) back to SwiftUI so
        /// the field frame grows with the draft, then caps and scrolls.
        func recomputeHeight() {
            guard let textView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let content = layoutManager.usedRect(for: container).height
                + textView.textContainerInset.height * 2
            let clamped = min(max(content, 0), parent.maxHeight)
            guard abs(clamped - parent.measuredHeight) > 0.5 else { return }
            DispatchQueue.main.async { self.parent.measuredHeight = clamped }
        }

        /// Intercept the keys the composer owns; everything else is stock text
        /// editing. Returning true consumes the command.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift+Return → real newline; plain Return → submit / accept.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    return false
                }
                parent.onReturn()
                return true
            case #selector(NSResponder.moveUp(_:)):
                return parent.onArrow(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onArrow(1)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            default:
                return false
            }
        }
    }
}

/// NSTextView that reports when IME marked (pre-edit) text appears or clears.
/// The input-context methods below are the only hooks that fire during a
/// composition — `textDidChange` doesn't — so this is how the composer learns
/// to drop its placeholder while pinyin/kana/etc. are still being composed.
private final class ComposingTextView: NSTextView {
    var onComposingChange: ((Bool) -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange,
                               replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange,
                            replacementRange: replacementRange)
        onComposingChange?(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onComposingChange?(hasMarkedText())
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onComposingChange?(hasMarkedText())
    }
}
#else
// MARK: - Composer text editor (iOS)

/// The iOS counterpart to the macOS composer editor: a UITextView-backed input
/// that grows to `maxHeight` then scrolls, and — unlike SwiftUI's
/// `TextField(axis:.vertical)` — doesn't re-lay out the whole draft on every
/// render, so big pastes stay smooth. Return submits (or accepts an open slash
/// completion); the ↑/↓/⇥/⎋ hardware-keyboard affordances are macOS-only for
/// now (the slash panel is tappable and the Stop button cancels a turn).
struct AcpComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    /// True while an IME composition (marked text) is on screen — the host uses
    /// it to hide the placeholder so it doesn't overlap the composing glyphs.
    @Binding var isComposing: Bool
    var isEditable: Bool
    var maxHeight: CGFloat
    var focusToken: Int
    var highlightLength: Int
    var onReturn: () -> Void
    var onArrow: (Int) -> Bool
    var onTab: () -> Bool
    var onEscape: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13.5)
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        textView.textContainer.lineFragmentPadding = 5
        textView.isScrollEnabled = true
        textView.keyboardDismissMode = .interactive
        textView.text = text
        context.coordinator.textView = textView
        // Deliberately NOT first responder on appear. The editor is built
        // whenever a pane's composer first lays out — selecting a pane, or
        // switching panes in Focus — so auto-focusing here threw the keyboard
        // up over the transcript on every pane switch. Raising it is the
        // user's call: tapping the field (UITextView's own behavior), or an
        // explicit `requestComposerFocus()` via `focusToken` below.
        DispatchQueue.main.async {
            context.coordinator.recomputeHeight()
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        var recompute = false
        if textView.text != text { textView.text = text; recompute = true }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        // A width change (rotation, layout) re-wraps the text → new height.
        if abs(textView.bounds.width - context.coordinator.lastWidth) > 0.5 {
            context.coordinator.lastWidth = textView.bounds.width
            recompute = true
        }
        if recompute { context.coordinator.recomputeHeight() }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AcpComposerTextEditor
        weak var textView: UITextView?
        var lastFocusToken: Int
        var lastWidth: CGFloat = 0

        init(_ parent: AcpComposerTextEditor) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func textViewDidChange(_ textView: UITextView) {
            let composing = textView.markedTextRange != nil
            if parent.isComposing != composing { parent.isComposing = composing }
            parent.text = textView.text
            recomputeHeight()
        }

        /// Return submits instead of inserting a newline (parity with the old
        /// field's onSubmit). Everything else types normally.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onReturn()
                return false
            }
            return true
        }

        /// Grow the field with the draft up to maxHeight, then let it scroll.
        /// Measured only on real edits / width changes — never per render — so
        /// a huge paste doesn't re-measure on every SwiftUI pass.
        func recomputeHeight() {
            guard let textView else { return }
            let width = textView.bounds.width > 0
                ? textView.bounds.width : UIScreen.main.bounds.width
            let fit = textView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude))
            // The SwiftUI frame caps the height; scrolling stays on so content
            // past the cap is reachable (below the cap it simply fits exactly).
            let clamped = min(max(fit.height, 0), parent.maxHeight)
            guard abs(clamped - parent.measuredHeight) > 0.5 else { return }
            DispatchQueue.main.async { self.parent.measuredHeight = clamped }
        }
    }
}
#endif
