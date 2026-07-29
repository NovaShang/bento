#if canImport(UIKit)
import UIKit
import BentoFoundation
import BentoUI
import BentoWorkbench
import BentoVoiceKit
import BentoFilePreviewKit
import BentoLink

// `TerminalColorTheme`, `ThemeStore`, `fromITermColors`, and the
// `.terminalThemeChanged` / `.terminalFontChanged` notifications now live in the
// shared `BentoCore` package (so macOS + iOS use one store and schema).
// Only the iOS-only UIKit color helpers remain here.

extension TerminalColorTheme {
    public var bgColor: UIColor { UIColor(hex: bg) }
    public var fgColor: UIColor { UIColor(hex: fg) }
    public var cursorColor: UIColor { UIColor(hex: cursor) }
}

#endif
