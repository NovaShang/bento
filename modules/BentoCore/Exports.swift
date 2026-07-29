// The umbrella: `import BentoCore` re-exports the whole module map, so the
// apps (and the tests) are untouched by the split. New code inside the
// package should import the specific module it needs, not this.

@_exported import BentoFoundation
@_exported import BentoUI
@_exported import BentoVoiceKit
@_exported import BentoFilePreviewKit
@_exported import BentoWorkbench
@_exported import BentoAgentPane
@_exported import BentoShellMac

import class Foundation.Bundle

/// The monolith's tests reached the PathPreview resources through the
/// module's own SPM-generated `Bundle.module` (internal, so visible via
/// `@testable import BentoCore`). After the split those resources belong to
/// BentoFilePreviewKit, whose generated accessor is internal to IT — this
/// package-level alias keeps `Bundle.module` meaning "the bundle with the
/// PathPreview assets" for in-package consumers of the umbrella.
extension Foundation.Bundle {
    package static var module: Bundle { .bentoFilePreviewKit }
}
