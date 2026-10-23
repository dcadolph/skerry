import Observation
import SwiftUI

/// AppearanceMode is the light and dark preference, or following the device.
enum AppearanceMode: String, CaseIterable, Identifiable {
    /// Follow the device setting.
    case system
    /// Force a light appearance.
    case light
    /// Force a dark appearance.
    case dark

    /// Stable identity for pickers.
    var id: String { rawValue }

    /// Menu label.
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// SwiftUI color scheme, nil when following the device.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    #if canImport(UIKit)
        /// UIKit interface style override; unspecified follows the device.
        var interfaceStyle: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
    #else
        /// AppKit appearance override; nil follows the device.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    #endif
}

/// AccentTheme is a named accent color. Some ship free, others belong to Skerry Plus.
struct AccentTheme: Identifiable, Equatable {
    /// Stable identity stored in preferences.
    let id: String
    /// Display name.
    let name: String
    /// Packed 0xRRGGBB color.
    let hex: UInt32
    /// Whether the color is a Skerry Plus perk.
    let plus: Bool

    /// SwiftUI color for chrome and controls.
    var color: Color { Color(hex: hex) }
    /// TextKit color for editor accents.
    var platformColor: PlatformColor { PlatformColor.fromHex(hex) }

    /// Every accent, free ones first, in catalog order.
    static let all: [AccentTheme] = [
        AccentTheme(id: "puffin", name: "Puffin", hex: 0xE0_7A_45, plus: false),
        AccentTheme(id: "tide", name: "Tide", hex: 0x3B_82_C4, plus: false),
        AccentTheme(id: "kelp", name: "Kelp", hex: 0x3E_9B_72, plus: false),
        AccentTheme(id: "fog", name: "Fog", hex: 0x8A_94_A6, plus: false),
        AccentTheme(id: "sunset", name: "Sunset", hex: 0xF2_60_3F, plus: true),
        AccentTheme(id: "aurora", name: "Aurora", hex: 0x7E_6B_F2, plus: true),
        AccentTheme(id: "berry", name: "Berry", hex: 0xD2_4E_86, plus: true),
        AccentTheme(id: "gold", name: "Gold", hex: 0xE0_A8_3C, plus: true),
    ]

    /// The default accent, Skerry's puffin-beak orange.
    static let fallback = all[0]

    /// Looks an accent up by id, falling back to the default.
    static func withID(_ id: String) -> AccentTheme {
        all.first { $0.id == id } ?? fallback
    }
}

/// EditorTheme is a full editor palette: background, ink, and code colors beyond the
/// accent. Some ship free, others belong to Skerry Plus.
struct EditorTheme: Identifiable, Equatable {
    /// Stable identity stored in preferences.
    let id: String
    /// Display name.
    let name: String
    /// Whether the theme is a Skerry Plus perk.
    let plus: Bool
    /// Editor background; nil follows the system.
    let background: UInt32?
    /// Body ink; nil follows the system label color.
    let text: UInt32?
    /// Code color; nil keeps the default.
    let code: UInt32?
    /// Appearance the palette is designed for; the editor adopts it while active.
    let scheme: AppearanceMode

    /// Every theme in catalog order, free ones first.
    static let all: [EditorTheme] = [
        EditorTheme(
            id: "system", name: "System", plus: false,
            background: nil, text: nil, code: nil, scheme: .system
        ),
        EditorTheme(
            id: "paper", name: "Paper", plus: false,
            background: 0xF7_F2_E7, text: 0x2B_26_20, code: 0x8A_4B_2D, scheme: .light
        ),
        EditorTheme(
            id: "dusk", name: "Dusk", plus: true,
            background: 0x10_17_20, text: 0xD8_E1_EC, code: 0x9A_B8_FF, scheme: .dark
        ),
        EditorTheme(
            id: "forest", name: "Forest", plus: true,
            background: 0x0F_1A_14, text: 0xDC_E8_DC, code: 0x8F_D6_94, scheme: .dark
        ),
        EditorTheme(
            id: "scary", name: "Scary Skerry", plus: true,
            background: 0x14_0A_1E, text: 0x8C_FF_3C, code: 0xC7_7D_FF, scheme: .dark
        ),
    ]

    /// The default system-following theme.
    static let fallback = all[0]

    /// Looks a theme up by id, falling back to the default.
    static func withID(_ id: String) -> EditorTheme {
        all.first { $0.id == id } ?? fallback
    }
}

/// EditorTextSize scales the editor's reading size without touching the file.
enum EditorTextSize: String, CaseIterable, Identifiable {
    case small, medium, large

    /// Stable identity for pickers.
    var id: String { rawValue }

    /// Menu label.
    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Multiplier applied to the base body and heading sizes.
    var scale: CGFloat {
        switch self {
        case .small: return 0.9
        case .medium: return 1.0
        case .large: return 1.15
        }
    }
}

/// AppSettings holds appearance and editor preferences, persisted in UserDefaults.
///
/// The store also pushes the resolved accent and text size into [MarkdownTheme] so the TextKit
/// editor tracks the same choices the SwiftUI chrome does.
@MainActor
@Observable
final class AppSettings {
    /// UserDefaults keys for each stored preference.
    private enum Key {
        static let appearance = "appearanceMode"
        static let accent = "accentTheme"
        static let textSize = "editorTextSize"
#if DEBUG
        static let plusPreview = "plusPreviewEnabled"
#endif
        static let typewriter = "typewriterMode"
        static let paragraphFocus = "paragraphFocus"
        static let editorTheme = "editorTheme"
        static let galleryLayout = "noteListGallery"
        static let listDensity = "noteListDensity"
        static let usesTextKit2 = "usesTextKit2"
    }

    /// Light and dark preference.
    var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    /// Pushes the appearance override into every window so open sheets restyle live.
    ///
    /// A window-level override instead of preferredColorScheme on purpose: changing that
    /// modifier while a sheet is up re-creates the presentation, which breaks the sheet's
    /// dismiss action and leaves it styled for the old scheme until closed.
    func applyAppearance() {
        #if canImport(UIKit)
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    window.overrideUserInterfaceStyle = appearanceMode.interfaceStyle
                }
            }
        #else
            NSApp.appearance = appearanceMode.nsAppearance
        #endif
    }

    /// Selected accent color.
    var accent: AccentTheme {
        didSet {
            UserDefaults.standard.set(accent.id, forKey: Key.accent)
            MarkdownTheme.accentOverride = accent.platformColor
        }
    }

    /// Editor reading size.
    var textSize: EditorTextSize {
        didSet {
            UserDefaults.standard.set(textSize.rawValue, forKey: Key.textSize)
            MarkdownTheme.sizeScale = textSize.scale
        }
    }

#if DEBUG
    /// Whether Plus features are unlocked for preview during development.
    var plusPreview: Bool {
        didSet {
            UserDefaults.standard.set(plusPreview, forKey: Key.plusPreview)
            PlusStore.shared.previewUnlocked = plusPreview
        }
    }
#endif

    /// Whether typewriter scrolling keeps the caret line vertically centered.
    var typewriterMode: Bool {
        didSet { UserDefaults.standard.set(typewriterMode, forKey: Key.typewriter) }
    }

    /// Editor palette in use.
    var editorTheme: EditorTheme {
        didSet {
            UserDefaults.standard.set(editorTheme.id, forKey: Key.editorTheme)
            applyEditorTheme()
        }
    }

    /// Pushes the theme's palette into the TextKit layer.
    private func applyEditorTheme() {
        MarkdownTheme.backgroundOverride = editorTheme.background.map(PlatformColor.fromHex)
        MarkdownTheme.textOverride = editorTheme.text.map(PlatformColor.fromHex)
        MarkdownTheme.codeOverride = editorTheme.code.map(PlatformColor.fromHex)
    }

    /// Whether paragraph focus dims everything except the paragraph being edited.
    var paragraphFocus: Bool {
        didSet { UserDefaults.standard.set(paragraphFocus, forKey: Key.paragraphFocus) }
    }

    /// Whether the note list shows gallery cards instead of rows.
    var galleryLayout: Bool {
        didSet { UserDefaults.standard.set(galleryLayout, forKey: Key.galleryLayout) }
    }

    /// How much air the note rows carry, from a tight scan to a roomy read.
    var listDensity: ListDensity {
        didSet { UserDefaults.standard.set(listDensity.rawValue, forKey: Key.listDensity) }
    }

    /// Whether the TextKit 2 editor backs the note editor. Defaults on; the classic
    /// TextKit 1 engine stays available for anyone who turns it off.
    var usesTextKit2: Bool {
        didSet { UserDefaults.standard.set(usesTextKit2, forKey: Key.usesTextKit2) }
    }

    /// Whether a Plus perk may be applied right now: owned, or previewed during development.
    func isUnlocked(plus: Bool) -> Bool { !plus || PlusStore.shared.isUnlocked(.appearance) }

    /// Whether a Plus accent may be applied right now.
    func isUnlocked(_ theme: AccentTheme) -> Bool { isUnlocked(plus: theme.plus) }

    /// Changes whenever a style choice changes, so the editor knows to re-highlight even when
    /// its text is unchanged.
    var styleToken: Int {
        var hasher = Hasher()
        hasher.combine(accent.id)
        hasher.combine(appearanceMode.rawValue)
        hasher.combine(textSize.rawValue)
        hasher.combine(paragraphFocus)
        hasher.combine(typewriterMode)
        hasher.combine(editorTheme.id)
        return hasher.finalize()
    }

    /// Loads saved preferences, or sensible defaults on first launch.
    init() {
        let defaults = UserDefaults.standard
        appearanceMode = AppearanceMode(
            rawValue: defaults.string(forKey: Key.appearance) ?? ""
        ) ?? .dark
        accent = AccentTheme.withID(defaults.string(forKey: Key.accent) ?? AccentTheme.fallback.id)
        textSize = EditorTextSize(
            rawValue: defaults.string(forKey: Key.textSize) ?? ""
        ) ?? .medium
#if DEBUG
        plusPreview = defaults.bool(forKey: Key.plusPreview)
#endif
        typewriterMode = defaults.bool(forKey: Key.typewriter)
        paragraphFocus = defaults.bool(forKey: Key.paragraphFocus)
        galleryLayout = defaults.bool(forKey: Key.galleryLayout)
        listDensity = ListDensity(rawValue: defaults.string(forKey: Key.listDensity) ?? "")
            ?? .comfortable
        usesTextKit2 = defaults.object(forKey: Key.usesTextKit2) as? Bool ?? true
        editorTheme = EditorTheme.withID(
            defaults.string(forKey: Key.editorTheme) ?? EditorTheme.fallback.id
        )
        MarkdownTheme.accentOverride = accent.platformColor
        MarkdownTheme.sizeScale = textSize.scale
        applyEditorTheme()
#if DEBUG
        PlusStore.shared.previewUnlocked = plusPreview
#endif
    }
}

extension Color {
    /// Builds a color from a packed 0xRRGGBB value.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension PlatformColor {
    /// Builds a platform color from a packed 0xRRGGBB value in sRGB.
    static func fromHex(_ hex: UInt32) -> PlatformColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        #if canImport(AppKit)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        #else
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        #endif
    }
}
