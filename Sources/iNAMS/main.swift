import AppKit

// Bootstraps the AppKit shell. `swift run iNAMS` works for development; the
// XcodeGen-produced bundle (project.yml) is the distributable form.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
