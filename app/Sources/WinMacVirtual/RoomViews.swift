import AppKit

/// Abgerundete Fläche für Kacheln und Hinweise; Farben folgen Hell/Dunkel.
class CardView: NSView {
    var fill: NSColor = .controlBackgroundColor { didSet { needsDisplay = true } }
    var border: NSColor = .separatorColor { didSet { needsDisplay = true } }

    init(radius: CGFloat = 10) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
    }
}

/// Anklickbare Kachel: Symbol, Titel, kurze Erklärung. Hover und Drücken wie bei Systemkacheln.
class TileButton: CardView {
    var onClick: (() -> Void)?
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : 0.45; setAccessibilityEnabled(isEnabled); updateState() }
    }
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    override init(radius: CGFloat = 10) {
        super.init(radius: radius)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Klicks gehen an die Kachel, nur eingebettete Knöpfe bleiben selbst anklickbar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateState() }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false; updateState() }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; pressed = true; updateState() }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let wasPressed = pressed
        pressed = false
        updateState()
        if wasPressed && inside && isEnabled { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    private func updateState() {
        let active = isEnabled && (hovering || pressed)
        fill = active ? NSColor.controlAccentColor.withAlphaComponent(pressed ? 0.18 : 0.08) : .controlBackgroundColor
        border = active ? NSColor.controlAccentColor.withAlphaComponent(0.45) : .separatorColor
    }
}

/// Farbiges Quadrat mit weißem SF-Symbol, wie in den Systemeinstellungen.
func symbolBadge(_ symbol: String, tint: NSColor, size: CGFloat = 32, pointSize: CGFloat = 15) -> NSView {
    let badge = CardView(radius: size * 0.25)
    badge.fill = tint
    badge.border = .clear
    let image = NSImageView()
    image.translatesAutoresizingMaskIntoConstraints = false
    image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
    image.contentTintColor = .white
    badge.addSubview(image)
    NSLayoutConstraint.activate([
        badge.widthAnchor.constraint(equalToConstant: size), badge.heightAnchor.constraint(equalToConstant: size),
        image.centerXAnchor.constraint(equalTo: badge.centerXAnchor), image.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
    ])
    return badge
}

/// Werkzeug-Kachel: Symbol links, Titel und eine Zeile Erklärung rechts.
final class ToolTile: TileButton {
    init(title: String, subtitle: String, symbol: String, tint: NSColor, action: @escaping () -> Void) {
        super.init()
        onClick = action
        setAccessibilityLabel(title)
        setAccessibilityHelp(subtitle)
        toolTip = subtitle
        let badge = symbolBadge(symbol, tint: tint)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for label in [name, detail] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [badge, text])
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 58)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// App-Kachel: Windows-Icon, Name, Status und ein runder Start-/Stopp-Knopf.
final class AppTile: TileButton {
    private let toggle: () -> Void

    init(program: Program, running: Bool, onOpen: @escaping () -> Void, onToggle: @escaping () -> Void, menu: NSMenu) {
        toggle = onToggle
        super.init()
        onClick = onOpen
        self.menu = menu
        setAccessibilityLabel(program.name)
        setAccessibilityHelp(running ? "Läuft" : "Details öffnen")
        toolTip = program.path

        let icon = NSImageView()
        icon.image = program.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: program.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSTextField(labelWithString: running ? "● Läuft" : (program.exists ? "Bereit" : "Datei nicht gefunden"))
        status.font = .systemFont(ofSize: 11, weight: running ? .medium : .regular)
        status.textColor = running ? .systemGreen : (program.exists ? .secondaryLabelColor : .systemOrange)
        let text = NSStackView(views: [name, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let button = NSButton(image: NSImage(systemSymbolName: running ? "stop.fill" : "play.fill",
                                             accessibilityDescription: running ? "Beenden" : "Starten")!,
                              target: nil, action: nil)
        button.target = self
        button.action = #selector(togglePressed)
        button.bezelStyle = .circular
        button.isBordered = true
        button.contentTintColor = running ? .systemRed : .controlAccentColor
        button.isEnabled = running || program.exists
        button.toolTip = running ? "Beenden" : "Starten"
        button.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [icon, text, button])
        row.distribution = .fill
        row.spacing = 10
        row.alignment = .centerY
        row.setCustomSpacing(6, after: text)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 34), icon.heightAnchor.constraint(equalToConstant: 34),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 62)
        ])
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func togglePressed() { toggle() }
}

/// Kleine Kapsel mit farbigem Punkt für den Zustand eines Raums.
func statusPill(_ text: String, color: NSColor) -> NSView {
    let pill = CardView(radius: 9)
    pill.fill = color.withAlphaComponent(0.14)
    pill.border = .clear
    let label = NSTextField(labelWithString: "● " + text)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = color
    label.translatesAutoresizingMaskIntoConstraints = false
    pill.addSubview(label)
    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
        label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
        label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        pill.heightAnchor.constraint(equalToConstant: 18)
    ])
    pill.setAccessibilityElement(true)
    pill.setAccessibilityLabel(text)
    return pill
}

/// Menüpunkt, der eine Closure ausführt.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, symbol: String? = nil, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// Inhalt der Detailseite: oben beginnend, nimmt .exe/.msi per Drag & Drop an.
final class DropDocumentView: NSView {
    var onDrop: (([URL]) -> Bool)?
    /// Meldet Breitenänderungen, damit Kachelraster ihre Spaltenzahl anpassen können.
    var onWidthChange: (() -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private var laidOutWidth: CGFloat = 0
    override func layout() {
        super.layout()
        guard frame.width != laidOutWidth else { return }
        laidOutWidth = frame.width
        onWidthChange?()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { Library.supportedExtensions.contains($0.pathExtension.lowercased()) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDrop != nil, !urls(sender).isEmpty else { return [] }
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        return onDrop?(urls(sender)) ?? false
    }
    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
