import Cocoa

// Explicit app entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Ensure we are a regular app (not background)
app.setActivationPolicy(.regular)

print("🚀 main.swift: Starting application...")
app.run()
