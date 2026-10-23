#if canImport(UIKit)

    import UIKit

    /// MarkdownAccessoryBar is the shortcut row above the keyboard: a scrolling strip of
    /// formatting buttons that matches the keyboard's chrome, with a pinned dismiss button.
    final class MarkdownAccessoryBar: UIInputView {
        /// One shortcut: an SF Symbol and what it does when tapped.
        struct Shortcut {
            /// SF Symbol name for the button.
            let symbol: String
            /// Work performed on tap.
            let action: () -> Void
        }

        /// Height of the bar, sized like a single keyboard shortcut row.
        static let barHeight: CGFloat = 46

        /// Builds the bar with scrolling format shortcuts, a help button, and a keyboard toggle.
        init(
            width: CGFloat, shortcuts: [Shortcut],
            onToggleKeyboard: @escaping () -> Void, onShowHelp: @escaping () -> Void
        ) {
            super.init(
                frame: CGRect(x: 0, y: 0, width: width, height: Self.barHeight),
                inputViewStyle: .keyboard
            )
            autoresizingMask = .flexibleWidth
            translatesAutoresizingMaskIntoConstraints = true

            let scroll = UIScrollView()
            scroll.showsHorizontalScrollIndicator = false
            scroll.translatesAutoresizingMaskIntoConstraints = false

            let stack = UIStackView(arrangedSubviews: shortcuts.map(Self.button(for:)))
            stack.axis = .horizontal
            stack.spacing = 4
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(stack)

            let separator = UIView()
            separator.backgroundColor = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false

            let help = UIButton(type: .system)
            help.setImage(
                UIImage(
                    systemName: "questionmark.circle",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                ), for: .normal
            )
            help.tintColor = .secondaryLabel
            help.translatesAutoresizingMaskIntoConstraints = false
            help.addAction(UIAction { _ in onShowHelp() }, for: .touchUpInside)

            let toggle = UIButton(type: .system)
            toggle.setImage(
                UIImage(
                    systemName: "keyboard.badge.ellipsis",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
                ), for: .normal
            )
            toggle.tintColor = .label
            toggle.translatesAutoresizingMaskIntoConstraints = false
            toggle.addAction(UIAction { _ in onToggleKeyboard() }, for: .touchUpInside)

            addSubview(scroll)
            addSubview(separator)
            addSubview(help)
            addSubview(toggle)

            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                scroll.topAnchor.constraint(equalTo: topAnchor),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
                scroll.trailingAnchor.constraint(equalTo: separator.leadingAnchor, constant: -4),

                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),

                separator.widthAnchor.constraint(equalToConstant: 0.5),
                separator.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                separator.trailingAnchor.constraint(equalTo: help.leadingAnchor, constant: -4),

                help.trailingAnchor.constraint(equalTo: toggle.leadingAnchor),
                help.centerYAnchor.constraint(equalTo: centerYAnchor),
                help.widthAnchor.constraint(equalToConstant: 36),

                toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
                toggle.widthAnchor.constraint(equalToConstant: 40),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// A single square icon button for one shortcut.
        private static func button(for shortcut: Shortcut) -> UIButton {
            let button = UIButton(type: .system)
            let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
            button.setImage(
                UIImage(systemName: shortcut.symbol, withConfiguration: config), for: .normal
            )
            button.tintColor = .label
            button.addAction(UIAction { _ in shortcut.action() }, for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            return button
        }
    }

    /// TagSuggestionBar replaces the shortcut row with tappable completions while a tag
    /// or wiki link is being typed.
    final class TagSuggestionBar: UIInputView {
        /// Builds the bar with word buttons for each suggestion.
        init(width: CGFloat, suggestions: [String], onPick: @escaping (String) -> Void) {
            super.init(
                frame: CGRect(x: 0, y: 0, width: width, height: MarkdownAccessoryBar.barHeight),
                inputViewStyle: .keyboard
            )
            autoresizingMask = .flexibleWidth
            translatesAutoresizingMaskIntoConstraints = true

            let scroll = UIScrollView()
            scroll.showsHorizontalScrollIndicator = false
            scroll.translatesAutoresizingMaskIntoConstraints = false

            let buttons = suggestions.map { suggestion -> UIButton in
                var configuration = UIButton.Configuration.gray()
                configuration.title = suggestion
                configuration.buttonSize = .small
                configuration.cornerStyle = .capsule
                let button = UIButton(configuration: configuration)
                button.addAction(UIAction { _ in onPick(suggestion) }, for: .touchUpInside)
                return button
            }
            let stack = UIStackView(arrangedSubviews: buttons)
            stack.axis = .horizontal
            stack.spacing = 6
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(stack)
            addSubview(scroll)

            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                scroll.topAnchor.constraint(equalTo: topAnchor),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

#endif
