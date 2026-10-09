import SwiftUI
import AppKit

@MainActor
final class LanguageStore: ObservableObject {
    @Published var language: AppLanguage

    init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage")
        language = AppLanguage(rawValue: saved ?? "zh-Hans") ?? .chinese
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        UserDefaults.standard.set(newLanguage.rawValue, forKey: "appLanguage")
        UserDefaults.standard.set([newLanguage.rawValue], forKey: "AppleLanguages")

        let alert = NSAlert()
        alert.messageText = newLanguage == .english ? "Restart AnaLine to apply the language" : "重启 AnaLine 以应用语言设置"
        alert.informativeText = newLanguage == .english
            ? "macOS menus apply the selected language when the app starts."
            : "macOS 菜单会在应用重新启动时应用所选语言。"
        alert.addButton(withTitle: newLanguage == .english ? "Restart Now" : "立即重启")
        alert.addButton(withTitle: newLanguage == .english ? "Later" : "稍后")
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    private func relaunch() {
        guard let executable = Bundle.main.executableURL else { NSApp.terminate(nil); return }
        do {
            let process = Process(); process.executableURL = executable
            try process.run(); NSApp.terminate(nil)
        } catch { NSApp.terminate(nil) }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }
    var title: String { self == .english ? "English" : "简体中文" }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.chinese.rawValue) ?? .chinese
    }

    static func localized(_ key: String) -> String {
        guard current == .chinese,
              let path = Bundle.main.path(forResource: AppLanguage.chinese.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

func L(_ key: String) -> String { AppLanguage.localized(key) }

struct AnaLineSettingsView: View {
    @ObservedObject var languageStore: LanguageStore

    var body: some View {
        Form {
            Picker(L("Language"), selection: Binding(
                get: { languageStore.language },
                set: { languageStore.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            Text(L("Choose the language used by Ana-Line's interface."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L("The macOS menu bar changes after AnaLine restarts."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 360)
        .environment(\.locale, Locale(identifier: languageStore.language.rawValue))
        .id(languageStore.language)
    }
}
