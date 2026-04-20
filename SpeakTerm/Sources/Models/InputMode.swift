import Foundation

/// The two primary interaction modes
enum InputMode: String, Codable {
    case voice    // Default: single-hand, hold-to-speak
    case keyboard // Two-hand: tap = focus + keyboard
}

/// Persists per-host input mode preference
final class InputModeStore: Sendable {
    static let shared = InputModeStore()
    private let key = "inputModePreferences"

    private init() {}

    func mode(for hostID: UUID) -> InputMode {
        let prefs = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return InputMode(rawValue: prefs[hostID.uuidString] ?? "") ?? .voice
    }

    func setMode(_ mode: InputMode, for hostID: UUID) {
        var prefs = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        prefs[hostID.uuidString] = mode.rawValue
        UserDefaults.standard.set(prefs, forKey: key)
    }
}
