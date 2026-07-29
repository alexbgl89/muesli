import CoreGraphics

/// Single wrapper around `CGWindowListCreateImage`, which macOS 14 deprecated in
/// favour of ScreenCaptureKit.
///
/// The call is kept deliberately rather than migrated, because the two are not
/// interchangeable here: `SCScreenshotManager` is async and needs an `SCWindow`
/// resolved from `SCShareableContent`, which changes both the call shape and the
/// permission behaviour of the two callers (computer-use window observation and
/// opt-in OCR screen context). That migration is tracked alongside the CoreAudio
/// tap work, which is what makes screenshots usable during meetings at all — see
/// `Context/handoff-2026-04-16-coreaudio-tap-migration.md`.
///
/// The remaining deprecation warning is deliberately left visible here, and only
/// here: it is a real migration signal, so hiding it would be worse than seeing
/// it. Routing all three former call sites through this one function collapses
/// three warnings into one, gives the migration a single place to land, and means
/// nothing else in the app can quietly reach for the old API.
///
/// Note that marking this shim `@available(macOS, deprecated:)` does *not* help:
/// Swift only suppresses a deprecation when the *caller* is itself deprecated, so
/// annotating the shim silences the call inside it while making every call site
/// warn instead — strictly worse.
enum LegacyWindowCapture {
    static func image(
        bounds: CGRect,
        listOption: CGWindowListOption,
        windowID: CGWindowID,
        imageOption: CGWindowImageOption
    ) -> CGImage? {
        CGWindowListCreateImage(bounds, listOption, windowID, imageOption)
    }
}
