import UIKit

/// Shown when the Aero page cannot be loaded.
final class FailureView: UIView {
    var onTryAgain: (() -> Void)?
    var onChangeAddress: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.06, green: 0.10, blue: 0.11, alpha: 1)

        let title = UILabel()
        title.text = "Can't reach Aero"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .white
        title.textAlignment = .center
        title.numberOfLines = 0

        let detail = UILabel()
        detail.text = "Check your connection, then try again."
        detail.font = .preferredFont(forTextStyle: .body)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = UIColor(white: 1, alpha: 0.7)
        detail.textAlignment = .center
        detail.numberOfLines = 0

        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.title = "Try again"
        let button = UIButton(configuration: buttonConfiguration, primaryAction: UIAction { [weak self] _ in
            self?.onTryAgain?()
        })

        var changeConfiguration = UIButton.Configuration.plain()
        changeConfiguration.title = "Change address"
        let change = UIButton(configuration: changeConfiguration, primaryAction: UIAction { [weak self] _ in
            self?.onChangeAddress?()
        })

        let stack = UIStackView(arrangedSubviews: [title, detail, button, change])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
