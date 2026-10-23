#if canImport(UIKit)

    import UIKit

    /// FormatKeyboard is the alternative keyboard: a grid of Markdown formatting keys that
    /// replaces the system keyboard, the way Bear's shortcut keyboard does.
    final class FormatKeyboard: UIInputView {
        /// One key: its face (SF Symbol or text) and the work it performs.
        struct Key {
            /// SF Symbol name, used when `title` is nil.
            var symbol: String?
            /// Text face for keys that read better as letters, such as H1 or B.
            var title: String?
            /// Whether the key is a prominent control rather than a plain format key.
            var prominent: Bool = false
            /// Work performed on tap.
            var action: () -> Void
        }

        /// Builds the keyboard from rows of keys.
        init(width: CGFloat, rows: [[Key]]) {
            super.init(
                frame: CGRect(x: 0, y: 0, width: width, height: 290),
                inputViewStyle: .keyboard
            )
            autoresizingMask = .flexibleWidth
            translatesAutoresizingMaskIntoConstraints = true

            let column = UIStackView()
            column.axis = .vertical
            column.distribution = .fillEqually
            column.spacing = 8
            column.translatesAutoresizingMaskIntoConstraints = false
            for row in rows {
                let line = UIStackView(arrangedSubviews: row.map(Self.button(for:)))
                line.axis = .horizontal
                line.distribution = .fillEqually
                line.spacing = 6
                column.addArrangedSubview(line)
            }
            addSubview(column)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                column.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// A single rounded key face for one grid key.
        private static func button(for key: Key) -> UIButton {
            var config = UIButton.Configuration.filled()
            config.cornerStyle = .large
            config.baseBackgroundColor = key.prominent
                ? .tertiarySystemFill : .secondarySystemFill
            config.baseForegroundColor = .label
            if let title = key.title {
                config.attributedTitle = AttributedString(
                    title,
                    attributes: AttributeContainer([
                        .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
                    ])
                )
            } else if let symbol = key.symbol {
                config.image = UIImage(
                    systemName: symbol,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
                )
            }
            let button = UIButton(configuration: config)
            button.configurationUpdateHandler = { button in
                button.alpha = button.isHighlighted ? 0.55 : 1
            }
            button.addAction(UIAction { _ in key.action() }, for: .touchUpInside)
            return button
        }
    }

#endif
