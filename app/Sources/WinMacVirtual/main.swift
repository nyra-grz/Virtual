import AppKit

// Ohne Fenster: Virtual --update  (siehe Updater.runFromCommandLine)
if CommandLine.arguments.contains("--update") {
    exit(Updater.shared.runFromCommandLine())
}
// Ohne Fenster: Virtual --install-engine  (Engine dieser Version laden, siehe EngineSetup)
if CommandLine.arguments.contains("--install-engine") {
    exit(EngineSetup.runFromCommandLine())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
