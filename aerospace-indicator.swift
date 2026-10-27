// Индикатор AeroSpace для меню-бара: показывает только воркспейс с фокусом,
// например «main-top», — без звёздочек и списка всех мониторов.
// Собирается и перезапускается из ~/.aerospace-render.sh,
// при старте AeroSpace запускается из after-startup-command.

import AppKit

let aerospace = "/opt/homebrew/bin/aerospace"
let lockPath = NSHomeDirectory() + "/.local/state/aerospace/indicator.lock"

// Второй экземпляр ждёт, пока завершится первый, и только потом занимает меню-бар
try? FileManager.default.createDirectory(
    atPath: (lockPath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true
)
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
flock(lockFD, LOCK_EX)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.title = "…"
item.menu = NSMenu()
item.menu?.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

func focusedWorkspace() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospace)
    process.arguments = ["list-workspaces", "--focused"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// В событии focused-workspace-changed есть поле workspace; если формат
// события поменяется, спрашиваем воркспейс с фокусом напрямую
func workspace(fromEvent line: String) -> String? {
    if let data = line.data(using: .utf8),
       let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let workspace = event["workspace"] as? String {
        return workspace
    }
    return focusedWorkspace()
}

// Обновляет заголовок, пока жив поток `aerospace subscribe`
func listen() async {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospace)
    process.arguments = ["subscribe", "focused-workspace-changed"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return }
    do {
        for try await line in pipe.fileHandleForReading.bytes.lines {
            guard let workspace = workspace(fromEvent: line), !workspace.isEmpty else { continue }
            await MainActor.run { item.button?.title = workspace }
        }
    } catch {}
    process.waitUntilExit()
}

Task.detached {
    while true {
        await listen()
        // Поток оборвался: AeroSpace перезапускается или завершился
        if NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty {
            exit(0)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}

app.run()
