// Индикатор AeroSpace для меню-бара: показывает только воркспейс с фокусом,
// Например «main-top» при нескольких экранах или «main» при одном.
// Собирается и перезапускается из ~/.aerospace-render.sh,
// при старте AeroSpace запускается из after-startup-command.

import AppKit

let environment = ProcessInfo.processInfo.environment
var commandEnvironment = environment
commandEnvironment.removeValue(forKey: "AEROSPACE_WINDOW_ID")
commandEnvironment.removeValue(forKey: "AEROSPACE_WORKSPACE")
let searchPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    + ["/opt/homebrew/bin", "/usr/local/bin"]
guard let aerospace = searchPaths.map({ $0 + "/aerospace" })
    .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
    fputs("aerospace не найден в PATH или Homebrew\n", stderr)
    exit(1)
}
let stateHome = environment["XDG_STATE_HOME"] ?? NSHomeDirectory() + "/.local/state"
let lockPath = stateHome + "/aerospace/indicator.lock"

// Повторный запуск не оставляет ожидающий процесс и не создаёт второй индикатор.
do {
    try FileManager.default.createDirectory(
        atPath: (lockPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
} catch {
    fputs("Не удалось создать каталог состояния: \(error)\n", stderr)
    exit(1)
}
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
guard lockFD >= 0 else { perror("indicator lock"); exit(1) }
guard fcntl(lockFD, F_SETFD, FD_CLOEXEC) == 0 else { perror("indicator lock flags"); exit(1) }
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    let alreadyRunning = errno == EWOULDBLOCK
    if !alreadyRunning { perror("indicator lock") }
    close(lockFD)
    exit(alreadyRunning ? 0 : 1)
}

func workspaceTitle(_ workspace: String, screenCount: Int) -> String {
    guard screenCount == 1 else { return workspace }
    for suffix in ["-mac", "-top", "-bottom"] where workspace.hasSuffix(suffix) {
        return String(workspace.dropLast(suffix.count))
    }
    return workspace
}

@MainActor final class IndicatorDelegate: NSObject, NSApplicationDelegate {
    var subscription: Process?
    var workspace = ""

    func updateTitle(workspace: String? = nil) {
        if let workspace { self.workspace = workspace }
        guard !self.workspace.isEmpty else { return }
        item.button?.title = workspaceTitle(self.workspace, screenCount: NSScreen.screens.count)
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        updateTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let process = subscription, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { IndicatorDelegate() }
app.delegate = delegate

// pkill из генератора должен закрывать и дочерний `aerospace subscribe`.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { app.terminate(nil) }
termination.resume()

let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.title = "…"
item.menu = NSMenu()
item.menu?.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

func focusedWorkspace() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospace)
    process.environment = commandEnvironment
    process.arguments = ["list-workspaces", "--focused"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
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
@MainActor func listen() async {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospace)
    process.environment = commandEnvironment
    process.arguments = ["subscribe", "focused-workspace-changed"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return }
    delegate.subscription = process
    defer {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        delegate.subscription = nil
    }
    do {
        for try await line in pipe.fileHandleForReading.bytes.lines {
            guard let workspace = workspace(fromEvent: line), !workspace.isEmpty else { continue }
            delegate.updateTitle(workspace: workspace)
        }
    } catch {}
}

Task { @MainActor in
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
