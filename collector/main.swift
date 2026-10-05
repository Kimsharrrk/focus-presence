// 포커스된 앱을 기록하는 메뉴바 수집기. 앱 전환 이벤트로 세션(앱, 시작, 끝)을 SQLite에 쓰고,
// 잠금/절전/화면보호기 동안은 기록을 멈춘다. 대시보드 서버(Node)도 함께 띄운다.
import Cocoa
import SQLite3

let env = ProcessInfo.processInfo.environment
let supportDir = env["FOCUS_DATA_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FocusTracker")
let dbPath = supportDir.appendingPathComponent("tracker.db").path
let configPath = supportDir.appendingPathComponent("config.json")
let port = env["PORT"] ?? "4317"
let dashboardURL = URL(string: "http://localhost:\(port)")!
let serverScript = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func now() -> Int { Int(Date().timeIntervalSince1970) }

func formatDuration(_ sec: Int) -> String {
    let h = sec / 3600, m = (sec % 3600) / 60
    return h > 0 ? "\(h)시간 \(m)분" : "\(m)분"
}

final class DB {
    var h: OpaquePointer?

    init() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard sqlite3_open(dbPath, &h) == SQLITE_OK else { fatalError("DB를 열 수 없음: \(dbPath)") }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA busy_timeout=3000")
        exec("""
            CREATE TABLE IF NOT EXISTS sessions(
              id INTEGER PRIMARY KEY,
              app TEXT NOT NULL,
              bundle_id TEXT,
              started_at INTEGER NOT NULL,
              ended_at INTEGER NOT NULL)
            """)
        exec("CREATE INDEX IF NOT EXISTS sessions_started_at ON sessions(started_at)")
        // ended_at은 5초마다 갱신되므로, 비정상 종료돼도 마지막 하트비트까지만 인정된다.
    }

    func exec(_ sql: String) { sqlite3_exec(h, sql, nil, nil, nil) }

    func insert(app: String, bundleID: String?, at t: Int) -> Int64 {
        var st: OpaquePointer?
        sqlite3_prepare_v2(h, "INSERT INTO sessions(app, bundle_id, started_at, ended_at) VALUES(?,?,?,?)", -1, &st, nil)
        sqlite3_bind_text(st, 1, app, -1, SQLITE_TRANSIENT)
        if let b = bundleID { sqlite3_bind_text(st, 2, b, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, 2) }
        sqlite3_bind_int64(st, 3, Int64(t))
        sqlite3_bind_int64(st, 4, Int64(t))
        sqlite3_step(st)
        sqlite3_finalize(st)
        return sqlite3_last_insert_rowid(h)
    }

    func touch(id: Int64, at t: Int) {
        var st: OpaquePointer?
        sqlite3_prepare_v2(h, "UPDATE sessions SET ended_at=? WHERE id=?", -1, &st, nil)
        sqlite3_bind_int64(st, 1, Int64(t))
        sqlite3_bind_int64(st, 2, id)
        sqlite3_step(st)
        sqlite3_finalize(st)
    }

    /// 오늘 0시 이후 해당 앱의 누적 초.
    func todaySeconds(app: String, since dayStart: Int) -> Int {
        var st: OpaquePointer?
        sqlite3_prepare_v2(h, "SELECT COALESCE(SUM(ended_at - MAX(started_at, ?1)), 0) FROM sessions WHERE app = ?2 AND ended_at > ?1", -1, &st, nil)
        sqlite3_bind_int64(st, 1, Int64(dayStart))
        sqlite3_bind_text(st, 2, app, -1, SQLITE_TRANSIENT)
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }
}

final class Tracker: NSObject {
    let db = DB()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var currentID: Int64?
    var currentApp: String?
    var excludedFocus = false
    var pauseReasons = Set<String>()
    var excluded = Set<String>()
    var server: Process?
    var sigtermSource: DispatchSourceSignal?

    func start() {
        let menu = NSMenu()
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "대시보드 열기", action: #selector(openDashboard), keyEquivalent: "d")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        observe()
        reloadConfig()
        startServerIfNeeded()
        switchTo(NSWorkspace.shared.frontmostApplication)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }

        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in self?.quitApp() }
        term.resume()
        sigtermSource = term
    }

    // MARK: 이벤트

    func observe() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            self?.switchTo(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        for (name, reason, pausing) in [
            (NSWorkspace.willSleepNotification, "sleep", true),
            (NSWorkspace.didWakeNotification, "sleep", false),
            (NSWorkspace.screensDidSleepNotification, "display", true),
            (NSWorkspace.screensDidWakeNotification, "display", false),
        ] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setPaused(reason, pausing) }
        }
        let dc = DistributedNotificationCenter.default()
        for (name, reason, pausing) in [
            ("com.apple.screenIsLocked", "lock", true),
            ("com.apple.screenIsUnlocked", "lock", false),
            ("com.apple.screensaver.didstart", "saver", true),
            ("com.apple.screensaver.didstop", "saver", false),
        ] {
            dc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in self?.setPaused(reason, pausing) }
        }
    }

    func setPaused(_ reason: String, _ pausing: Bool) {
        if pausing { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        switchTo(NSWorkspace.shared.frontmostApplication)
    }

    // MARK: 세션

    func closeSession() {
        if let id = currentID { db.touch(id: id, at: now()) }
        currentID = nil
        currentApp = nil
    }

    func switchTo(_ app: NSRunningApplication?) {
        excludedFocus = false
        guard pauseReasons.isEmpty, let app, let name = app.localizedName else {
            closeSession(); refreshMenu(); return
        }
        if isExcluded(app) {
            closeSession(); excludedFocus = true; refreshMenu(); return
        }
        if currentID != nil, currentApp == name { refreshMenu(); return } // 같은 앱이 이어지면 한 세션
        closeSession()
        currentID = db.insert(app: name, bundleID: app.bundleIdentifier, at: now())
        currentApp = name
        refreshMenu()
    }

    func isExcluded(_ app: NSRunningApplication) -> Bool {
        excluded.contains(app.localizedName ?? "") || excluded.contains(app.bundleIdentifier ?? "")
    }

    func tick() {
        reloadConfig()
        startServerIfNeeded()
        // 놓친 알림이 있어도 5초 안에 바로잡는다. 같은 앱이면 세션이 합쳐진다.
        switchTo(NSWorkspace.shared.frontmostApplication)
        if let id = currentID { db.touch(id: id, at: now()) }
        refreshMenu()
    }

    // MARK: 설정, 메뉴, 서버

    func reloadConfig() {
        guard let data = try? Data(contentsOf: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["excludedApps"] as? [String] else { return }
        excluded = Set(list)
    }

    func refreshMenu() {
        let button = statusItem.button
        if !pauseReasons.isEmpty {
            button?.title = "⏸ 일시정지"
            infoItem.title = "잠금/절전 중이라 기록하지 않음"
        } else if excludedFocus {
            button?.title = "🔒 제외된 앱"
            infoItem.title = "제외 앱은 기록하지 않음"
        } else if let app = currentApp {
            let dayStart = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
            let total = formatDuration(db.todaySeconds(app: app, since: dayStart))
            button?.title = "● \(app) · \(total)"
            infoItem.title = "지금 \(app) — 오늘 \(total)"
        } else {
            button?.title = "—"
            infoItem.title = "포커스된 앱 없음"
        }
    }

    func startServerIfNeeded() {
        guard let script = serverScript, server?.isRunning != true else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", script]
        var e = env
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = e
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        server = p
    }

    @objc func openDashboard() { NSWorkspace.shared.open(dashboardURL) }

    @objc func quitApp() {
        closeSession()
        server?.terminate()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let tracker = Tracker()
tracker.start()
app.run()
