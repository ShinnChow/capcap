import AppKit

/// Content of the Settings "翻译" tab: one editable config card per AI
/// translation provider. The target language follows the app language.
final class TranslationSettingsPane: NSView {
    private var providerCards: [TranslationProviderCard] = []
    private var providersHeaderLabel: NSTextField!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: .languageDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Providers header.
        providersHeaderLabel = makeLabel(L10n.translationProvidersHeader, size: 12, weight: .semibold, alpha: 0.62)
        stack.addArrangedSubview(providersHeaderLabel)

        // Provider cards.
        for kind in TranslationProviderKind.allCases {
            let card = TranslationProviderCard(kind: kind)
            card.translatesAutoresizingMaskIntoConstraints = false
            providerCards.append(card)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])
    }

    @objc private func onLanguageChanged() {
        providersHeaderLabel.stringValue = L10n.translationProvidersHeader
        for card in providerCards { card.refreshLocalization() }
    }
}

// MARK: - Pasteable text field

/// Text field that honors Cmd+C/V/X/A in a menu-less LSUIElement app.
private final class TKTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector
        switch event.charactersIgnoringModifiers {
        case "x": action = #selector(NSText.cut(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default: return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
}

// MARK: - Provider card

private final class TranslationProviderCard: NSView {
    private let kind: TranslationProviderKind
    private let titleLabel = NSTextField(labelWithString: "")
    private let enableSwitch = NSSwitch()
    private let apiKeyField = RevealableSecureField()
    private let modelField = TKTextField()
    private let endpointField = TKTextField()
    private let apiKeyLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let endpointLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private let bodyContainer = NSView()

    init(kind: TranslationProviderKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
        buildUI()
        loadFromStore()
        let enabled = TranslationConfigStore.isEnabled(kind)
        enableSwitch.state = enabled ? .on : .off
        bodyContainer.isHidden = !enabled
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        pin(outer, to: self, inset: 14)

        // Header.
        titleLabel.stringValue = kind.displayName
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.94)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        enableSwitch.controlSize = .small
        enableSwitch.target = self
        enableSwitch.action = #selector(switchToggled)
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, flexSpacer(), enableSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true

        // Body.
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            body.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])

        body.addArrangedSubview(makeFieldRow(apiKeyLabel, apiKeyField,
                                             label: L10n.translationApiKey,
                                             placeholder: "sk-…", width: body))
        body.addArrangedSubview(makeFieldRow(modelLabel, modelField,
                                             label: L10n.translationModel,
                                             placeholder: modelPlaceholder(), width: body))
        body.addArrangedSubview(makeFieldRow(endpointLabel, endpointField,
                                             label: endpointLabelText(),
                                             placeholder: endpointPlaceholder(), width: body))

        saveButton.title = L10n.translationSave
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(saveTapped)

        clearButton.title = L10n.translationClear
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearTapped)

        let footer = NSStackView(views: [flexSpacer(), clearButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        outer.addArrangedSubview(bodyContainer)
        bodyContainer.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
    }

    private func makeFieldRow(_ label: NSTextField, _ field: any ProviderFieldInput,
                              label labelText: String, placeholder: String,
                              width: NSView) -> NSView {
        label.stringValue = labelText
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = NSColor.white.withAlphaComponent(0.74)
        label.alignment = .right
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true

        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return row
    }

    // MARK: Field metadata

    private func modelPlaceholder() -> String {
        if kind.isDeepL {
            return "quality_optimized / prefer_quality_optimized / latency_optimized"
        }
        return kind.defaultModel.isEmpty ? "e.g. gpt-4o-mini" : kind.defaultModel
    }

    private func endpointLabelText() -> String {
        kind.endpointRequired ? L10n.translationEndpoint : L10n.translationEndpointOptional
    }

    private func endpointPlaceholder() -> String {
        kind.defaultEndpoint.isEmpty
            ? "https://api.example.com/v1/chat/completions"
            : kind.defaultEndpoint
    }

    // MARK: Persistence

    private func loadFromStore() {
        let cfg = TranslationConfigStore.load(kind)
        apiKeyField.stringValue = cfg.apiKey
        modelField.stringValue = cfg.model
        endpointField.stringValue = cfg.endpoint
    }

    private func currentConfig() -> TranslationConfig {
        TranslationConfig(
            apiKey: apiKeyField.stringValue,
            model: modelField.stringValue,
            endpoint: endpointField.stringValue
        )
    }

    @objc private func switchToggled() {
        let on = enableSwitch.state == .on
        if on { TranslationConfigStore.save(currentConfig(), for: kind) }
        TranslationConfigStore.setEnabled(on, for: kind)
        bodyContainer.isHidden = !on
    }

    @objc private func saveTapped() {
        let config = currentConfig()
        TranslationConfigStore.save(config, for: kind)

        // Nothing to test against without an API key — just confirm the save.
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flashButton(saveButton, to: L10n.translationConfigSaved, restore: L10n.translationSave)
            return
        }

        saveButton.isEnabled = false
        clearButton.isEnabled = false
        saveButton.title = L10n.translationTesting

        let testedKind = kind
        Task { [weak self] in
            let error = await TranslationService.verify(kind: testedKind, config: config)
            await MainActor.run {
                guard let self else { return }
                self.saveButton.isEnabled = true
                self.clearButton.isEnabled = true
                if let error {
                    flashButton(self.saveButton, to: L10n.translationTestFailed,
                                restore: L10n.translationSave)
                    self.showTestFailure(error)
                } else {
                    flashButton(self.saveButton, to: L10n.translationTestPassed,
                                restore: L10n.translationSave)
                }
            }
        }
    }

    /// Reports a failed connection test. The config was already saved.
    private func showTestFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.translationTestFailedTitle
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    @objc private func clearTapped() {
        apiKeyField.stringValue = ""
        modelField.stringValue = ""
        endpointField.stringValue = ""
        TranslationConfigStore.clear(kind)
    }

    func refreshLocalization() {
        titleLabel.stringValue = kind.displayName
        apiKeyLabel.stringValue = L10n.translationApiKey
        modelLabel.stringValue = L10n.translationModel
        endpointLabel.stringValue = endpointLabelText()
        saveButton.title = L10n.translationSave
        clearButton.title = L10n.translationClear
    }
}
