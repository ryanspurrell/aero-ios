import UIKit

/// First launch: one field for the server's address and a Connect key.
/// Also reached from "Change address" on the unreachable screen.
final class SetupView: UIView {
    /// Called with the checked address once it answers.
    var onConnected: ((URL) -> Void)?

    private let field = UITextField()
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.06, green: 0.10, blue: 0.11, alpha: 1)

        let title = UILabel()
        title.text = "Connect to Aero"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .white
        title.textAlignment = .center
        title.numberOfLines = 0

        let help = UILabel()
        help.text = "Enter the address you use to open Aero in Safari. Aero adds https if you leave it off."
        help.font = .preferredFont(forTextStyle: .body)
        help.adjustsFontForContentSizeCategory = true
        help.textColor = UIColor(white: 1, alpha: 0.7)
        help.textAlignment = .center
        help.numberOfLines = 0

        field.placeholder = "Server address"
        field.borderStyle = .roundedRect
        field.keyboardType = .URL
        field.textContentType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.text = AppInfo.address?.absoluteString ?? AppInfo.defaultAddress
        field.addAction(UIAction { [weak self] _ in self?.connect() }, for: .editingDidEndOnExit)

        message.font = .preferredFont(forTextStyle: .footnote)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = UIColor(red: 1, green: 0.55, blue: 0.5, alpha: 1)
        message.textAlignment = .center
        message.numberOfLines = 0

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Connect"
        button.configuration = configuration
        button.addAction(UIAction { [weak self] _ in self?.connect() }, for: .touchUpInside)

        spinner.color = .white

        let stack = UIStackView(arrangedSubviews: [title, help, field, message, button, spinner])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 64),
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Clears the last message and puts the saved address back in the field.
    func prepare() {
        message.text = nil
        field.text = AppInfo.address?.absoluteString ?? AppInfo.defaultAddress
    }

    private func connect() {
        field.resignFirstResponder()
        let url: URL
        switch AddressChecker.normalize(field.text ?? "") {
        case .failure(let problem):
            message.textColor = UIColor(red: 1, green: 0.55, blue: 0.5, alpha: 1)
            message.text = problem.message
            return
        case .success(let checked):
            url = checked
        }
        message.text = "Checking the address…"
        message.textColor = UIColor(white: 1, alpha: 0.7)
        button.isEnabled = false
        spinner.startAnimating()
        Task { @MainActor in
            let problem = await AddressChecker.check(url)
            spinner.stopAnimating()
            button.isEnabled = true
            if let problem {
                message.textColor = UIColor(red: 1, green: 0.55, blue: 0.5, alpha: 1)
                message.text = problem.message
            } else {
                message.text = nil
                AppInfo.address = url
                onConnected?(url)
            }
        }
    }
}
