import AppKit
import Carbon

/// Kiosk-Apps (Fenster ohne Rahmen über den ganzen Bildschirm) liegen als großes Fenster über
/// normalen Mac-Apps, statt den Mac zu sperren; das erledigt der Mac-Treiber der Runtime
/// (`VIRTUAL_KIOSK_OVERLAY`). Hier sitzt nur die Tastenkombination, die sie verkleinert und
/// wieder vergrößert. Sie ist nur registriert, solange Windows-Programme laufen.
final class OverlayController {
    static let shared = OverlayController()
    static let notification = Notification.Name("com.oezdek.virtual.kiosk")
    private(set) var shrunk = false
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: (UInt32, UInt32)?

    struct Shortcut: Equatable {
        var key: UInt32
        var modifiers: UInt32
        var title: String
        static var standard: Shortcut { Shortcut(key: keyCodeForZ(), modifiers: UInt32(cmdKey | optionKey), title: "⌥⌘Z") }
        private static func keyCodeForZ() -> UInt32 {
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return 6 }
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            for key: UInt16 in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 8, &length, &chars)
                if status == noErr && length == 1 && chars[0] == 122 { return UInt32(key) }
            }
            return 6
        }
    }

    private init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<OverlayController>.fromOpaque(context).takeUnretainedValue().toggle()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        NotificationCenter.default.addObserver(forName: Launcher.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.update()
        }
    }

    enum OverlayError: LocalizedError {
        case shortcut(OSStatus)
        var errorDescription: String? {
            switch self {
            case .shortcut: return "Diese Tastenkombination ist schon belegt oder nicht verfügbar. Bitte eine andere wählen."
            }
        }
    }

    /// Prüft eine neue Kombination und ersetzt die aktive Registrierung erst, wenn sie frei ist.
    func configure(_ shortcut: Shortcut) throws {
        if let registered, registered.0 == shortcut.key && registered.1 == shortcut.modifiers { return }
        var candidate: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5652544c, id: 1)
        let status = RegisterEventHotKey(shortcut.key, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr else { throw OverlayError.shortcut(status) }
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = candidate
        registered = (shortcut.key, shortcut.modifiers)
        update()
    }

    /// Registriert die Kombination, solange Programme laufen; danach ist sie wieder frei.
    func update() {
        if Settings.shared.overlayEnabled && Launcher.shared.hasRunning {
            if hotkey == nil { try? configure(Settings.shared.overlayShortcut) }
        } else {
            if let hotkey { UnregisterEventHotKey(hotkey) }
            hotkey = nil
            registered = nil
            shrunk = false
        }
    }

    @objc func toggle() {
        guard Launcher.shared.hasRunning else { return }
        shrunk.toggle()
        DistributedNotificationCenter.default().postNotificationName(Self.notification, object: nil,
                                                                     userInfo: ["shrunk": shrunk], deliverImmediately: true)
    }
}

/// Erfasst echte Tastencodes statt textbasierter Kombinationen; funktioniert auch außerhalb Virtual.
final class ShortcutRecorder: NSButton {
    var shortcut = Settings.shared.overlayShortcut { didSet { if !recording { title = shortcut.title } } }
    private var recording = false
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        title = shortcut.title
        target = self
        action = #selector(record)
        setAccessibilityLabel("Tastenkombination für Bildschirm-Overlay")
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func record() { recording = true; title = "Jetzt Tasten drücken…"; window?.makeFirstResponder(self) }
    override func resignFirstResponder() -> Bool { recording = false; title = shortcut.title; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = shortcut.title; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control),
              let text = event.charactersIgnoringModifiers, !text.isEmpty else { NSSound.beep(); return }
        var mods: UInt32 = 0
        var display = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); display += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); display += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); display += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); display += "⌘" }
        shortcut = .init(key: UInt32(event.keyCode), modifiers: mods, title: display + text.uppercased())
        recording = false
        title = shortcut.title
    }
}
