import AppKit

/// Localization helper with runtime language switching support
func L(_ key: String) -> String {
    // Check if a custom language override is set
    if let lang = UserDefaults.standard.string(forKey: "selectedLanguage"),
       let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
    return NSLocalizedString(key, comment: "")
}

/// The locale matching the language chosen in Settings (or the system's when none is),
/// so dates and numbers read the same way as the surrounding text.
enum AppLocale {
    static var current: Locale {
        if let language = UserDefaults.standard.string(forKey: "selectedLanguage"), !language.isEmpty {
            return Locale(identifier: language)
        }
        return Locale.current
    }
}

/// Localization helper with format arguments
func L(_ key: String, _ args: CVarArg...) -> String {
    let template: String
    if let lang = UserDefaults.standard.string(forKey: "selectedLanguage"),
       let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        template = bundle.localizedString(forKey: key, value: nil, table: nil)
    } else {
        template = NSLocalizedString(key, comment: "")
    }
    return String(format: template, arguments: args)
}

/// Width of a right-aligned label column that fits every label in it in the current
/// language — Russian and Tajik labels run much longer than their English originals.
func fittingLabelWidth(_ labels: [String], minimum: CGFloat) -> CGFloat {
    let widest = labels.map { NSTextField(labelWithString: $0).fittingSize.width }.max() ?? 0
    return max(minimum, ceil(widest) + 2)
}
