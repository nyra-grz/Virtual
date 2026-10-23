import AppKit

// Ohne Fenster: Virtual --update  (siehe Updater.runFromCommandLine)
if CommandLine.arguments.contains("--update") {
    exit(Updater.shared.runFromCommandLine())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
