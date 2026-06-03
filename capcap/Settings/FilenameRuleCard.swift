import AppKit

final class FilenameRuleCard: NSView, NSTextFieldDelegate {
    private enum Preset: Int, CaseIterable {
        case custom
        case short
        case compact
        case unique
        case counter
        case restore

        var title: String {
            switch self {
            case .custom: return L10n.filenameRulePresetCustom
            case .short: return L10n.filenameRulePresetShort
            case .compact: return L10n.filenameRulePresetCompact
            case .unique: return L10n.filenameRulePresetUnique
            case .counter: return L10n.filenameRulePresetCounter
            case .restore: return L10n.filenameRulePresetRestore
            }
        }

        var imageTemplate: String {
            switch self {
            case .custom: return Defaults.imageFilenameTemplate
            case .short: return "capcap-{date}-{time}"
            case .compact: return "c-{date}-{time}"
            case .unique: return "capcap-{date}-{time}-{rand:3}"
            case .counter: return "capcap-{date}-{daily:3}"
            case .restore: return Defaults.defaultImageFilenameTemplate
            }
        }

        var recordingTemplate: String {
            switch self {
            case .custom: return Defaults.recordingFilenameTemplate
            case .short: return "capcap-rec-{date}-{time}"
            case .compact: return "r-{date}-{time}"
            case .unique: return "capcap-rec-{date}-{time}-{rand:3}"
            case .counter: return "capcap-rec-{date}-{daily:3}"
            case .restore: return Defaults.defaultRecordingFilenameTemplate
            }
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let presetLabel = NSTextField(labelWithString: "")
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let imageLabel = NSTextField(labelWithString: "")
    private let recordingLabel = NSTextField(labelWithString: "")
    private let variablesLabel = NSTextField(labelWithString: "")
    private let imageField = PasteableTextField()
    private let recordingField = PasteableTextField()
    private let imagePreviewLabel = NSTextField(labelWithString: "")
    private let recordingPreviewLabel = NSTextField(labelWithString: "")
    private var variableButtons: [(button: NSButton, token: String)] = []
    private weak var activeField: NSTextField?
    private var imageCursorLocation = 0
    private var recordingCursorLocation = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1

        imageField.stringValue = Defaults.imageFilenameTemplate
        recordingField.stringValue = Defaults.recordingFilenameTemplate
        imageField.delegate = self
        recordingField.delegate = self
        imageCursorLocation = (imageField.stringValue as NSString).length
        recordingCursorLocation = (recordingField.stringValue as NSString).length
        activeField = imageField

        buildUI()
        refreshLocalization()
        updatePreviews()
        syncPresetSelection()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshLocalization() {
        titleLabel.stringValue = L10n.filenameRuleTitle
        subtitleLabel.stringValue = L10n.filenameRuleSubtitle
        presetLabel.stringValue = L10n.filenameRulePresetLabel
        imageLabel.stringValue = L10n.filenameRuleImageLabel
        recordingLabel.stringValue = L10n.filenameRuleRecordingLabel
        variablesLabel.stringValue = L10n.filenameRuleVariablesLabel

        let selected = presetPopup.indexOfSelectedItem
        presetPopup.removeAllItems()
        Preset.allCases.forEach { presetPopup.addItem(withTitle: $0.title) }
        if selected >= 0, selected < presetPopup.numberOfItems {
            presetPopup.selectItem(at: selected)
        }

        let labels = [
            L10n.filenameRuleVariableDate,
            L10n.filenameRuleVariableTime,
            L10n.filenameRuleVariableDaily,
            L10n.filenameRuleVariableRandom,
            L10n.filenameRuleVariableSize,
        ]
        for (index, label) in labels.enumerated() where index < variableButtons.count {
            variableButtons[index].button.title = label
        }
        updatePreviews()
        syncPresetSelection()
    }

    private func buildUI() {
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.94)

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        header.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        subtitleLabel.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        let presetStack = labeledControlStack(label: presetLabel, control: presetPopup)
        presetPopup.controlSize = .small
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        presetPopup.translatesAutoresizingMaskIntoConstraints = false
        presetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        inner.addArrangedSubview(presetStack)

        let imageSection = makeTemplateSection(label: imageLabel, field: imageField, preview: imagePreviewLabel)
        let recordingSection = makeTemplateSection(label: recordingLabel, field: recordingField, preview: recordingPreviewLabel)
        inner.addArrangedSubview(imageSection)
        imageSection.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        inner.addArrangedSubview(recordingSection)
        recordingSection.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        inner.addArrangedSubview(makeVariablesSection())

        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            inner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private func labeledControlStack(label: NSTextField, control: NSView) -> NSStackView {
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.74)
        label.alignment = .left

        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeTemplateSection(label: NSTextField, field: NSTextField, preview: NSTextField) -> NSStackView {
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false

        preview.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.textColor = NSColor.white.withAlphaComponent(0.55)
        preview.alignment = .left
        preview.lineBreakMode = .byTruncatingMiddle
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = labeledControlStack(label: label, control: field)
        stack.addArrangedSubview(preview)

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        return stack
    }

    private func makeVariablesSection() -> NSStackView {
        variablesLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        variablesLabel.textColor = NSColor.white.withAlphaComponent(0.74)
        variablesLabel.alignment = .left

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let tokens = ["{date}", "{time}", "{daily:3}", "{rand:4}", "{width}x{height}"]
        for token in tokens {
            let button = NSButton(title: "", target: self, action: #selector(insertVariable(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 11)
            button.identifier = NSUserInterfaceItemIdentifier(token)
            button.refusesFirstResponder = true
            variableButtons.append((button, token))
            buttonRow.addArrangedSubview(button)
        }

        let stack = NSStackView(views: [variablesLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        guard let preset = Preset(rawValue: sender.indexOfSelectedItem), preset != .custom else {
            return
        }
        imageField.stringValue = preset.imageTemplate
        recordingField.stringValue = preset.recordingTemplate
        imageCursorLocation = (imageField.stringValue as NSString).length
        recordingCursorLocation = (recordingField.stringValue as NSString).length
        persistTemplates()
        updatePreviews()
        syncPresetSelection()
    }

    @objc private func insertVariable(_ sender: NSButton) {
        let token = sender.identifier?.rawValue ?? ""
        guard !token.isEmpty else { return }
        let field = activeField ?? imageField
        updateStoredCursor(for: field)

        let insertionLocation: Int
        let newLocation: Int
        if let editor = field.currentEditor() {
            let textLength = (editor.string as NSString).length
            insertionLocation = min(max(storedCursorLocation(for: field), 0), textLength)
            editor.replaceCharacters(in: NSRange(location: insertionLocation, length: 0), with: token)
            newLocation = insertionLocation + (token as NSString).length
            editor.selectedRange = NSRange(location: newLocation, length: 0)
            field.stringValue = editor.string
        } else {
            let mutable = NSMutableString(string: field.stringValue)
            insertionLocation = min(max(storedCursorLocation(for: field), 0), mutable.length)
            mutable.insert(token, at: insertionLocation)
            newLocation = insertionLocation + (token as NSString).length
            field.stringValue = mutable as String
        }

        setStoredCursorLocation(newLocation, for: field)
        persistTemplates()
        updatePreviews()
        syncPresetSelection()

        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: newLocation, length: 0)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        activeField = field
        updateStoredCursor(for: field)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        updateStoredCursor(for: field)
        persistTemplates()
        updatePreviews()
        syncPresetSelection()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        updateStoredCursor(for: field)
    }

    private func updateStoredCursor(for field: NSTextField) {
        guard let editor = field.currentEditor() else { return }
        setStoredCursorLocation(editor.selectedRange.location, for: field)
    }

    private func storedCursorLocation(for field: NSTextField) -> Int {
        field === recordingField ? recordingCursorLocation : imageCursorLocation
    }

    private func setStoredCursorLocation(_ location: Int, for field: NSTextField) {
        let length = (field.stringValue as NSString).length
        let clamped = min(max(location, 0), length)
        if field === recordingField {
            recordingCursorLocation = clamped
        } else {
            imageCursorLocation = clamped
        }
    }

    private func persistTemplates() {
        Defaults.imageFilenameTemplate = imageField.stringValue
        Defaults.recordingFilenameTemplate = recordingField.stringValue
    }

    private func updatePreviews() {
        imagePreviewLabel.stringValue = L10n.filenameRulePreview(
            FilenameTemplate.previewFileName(
                kind: .image,
                template: imageField.stringValue,
                fileExtension: "png"
            )
        )
        recordingPreviewLabel.stringValue = L10n.filenameRulePreview(
            FilenameTemplate.previewFileName(
                kind: .recording,
                template: recordingField.stringValue,
                fileExtension: "mp4",
                imageSize: nil
            )
        )
    }

    private func syncPresetSelection() {
        let imageTemplate = imageField.stringValue
        let recordingTemplate = recordingField.stringValue
        let matchingPreset = Preset.allCases.first { preset in
            guard preset != .custom, preset != .restore else { return false }
            return preset.imageTemplate == imageTemplate && preset.recordingTemplate == recordingTemplate
        }
        presetPopup.selectItem(at: (matchingPreset ?? .custom).rawValue)
    }
}
