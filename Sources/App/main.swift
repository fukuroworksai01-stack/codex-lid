import AppKit
import Darwin
import Foundation

private struct SessionStatus: Codable {
  let sessionID: String
  let state: String
  let reason: String
  let startedAt: Int64
  let expiresAt: Int64
  let deadlineTicks: UInt64
  let powerSource: String
  let batteryPercent: Int
  let thermalState: String
  let pid: Int32
}

private enum SleepSettingState {
  case enabled
  case disabled
  case absent
  case unknown
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let uid = getuid()
  private lazy var runtimeDirectory = "/private/tmp/codex-lid-\(uid)"
  private lazy var statusPath = runtimeDirectory + "/status.json"
  private lazy var stopPath = runtimeDirectory + "/stop.request"
  private let maximumStatusBytes = 16 * 1024
  private let activeSessionPath = "/var/run/com.fukuroworks.codexlid.active"
  private let protectedAppPath =
    "/Library/Application Support/Codex Lid/Codex Lid.app"
  private let privilegedWorkerPath =
    "/Library/Application Support/Codex Lid/Codex Lid.app/Contents/Resources/CodexLidWorker"
  private var runtimeDirectoryReady = false
  private var privilegedWorkerReady = false

  private var statusItem: NSStatusItem!
  private let menu = NSMenu()
  private var refreshTimer: Timer?

  private let summaryItem = NSMenuItem(title: "状態を確認中…", action: nil, keyEquivalent: "")
  private let remainingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let start5Item = NSMenuItem(
    title: "5分テスト（初回推奨）", action: #selector(start5), keyEquivalent: "")
  private let start30Item = NSMenuItem(
    title: "30分だけ続ける", action: #selector(start30), keyEquivalent: "")
  private let start60Item = NSMenuItem(
    title: "1時間だけ続ける", action: #selector(start60), keyEquivalent: "")
  private let start120Item = NSMenuItem(
    title: "2時間だけ続ける", action: #selector(start120), keyEquivalent: "")
  private let batteryItem = NSMenuItem(
    title: "バッテリー動作を許可（25%で停止）", action: #selector(toggleBatteryMode), keyEquivalent: "")
  private let stopItem = NSMenuItem(
    title: "停止して通常スリープへ戻す", action: #selector(stopSession), keyEquivalent: "")
  private let lockItem = NSMenuItem(
    title: "画面を消してロック", action: #selector(lockScreen), keyEquivalent: "l")
  private let emergencyResetItem = NSMenuItem(
    title: "緊急復旧：スリープ設定を戻す…", action: #selector(emergencyReset), keyEquivalent: "")

  private var allowBattery: Bool {
    get { UserDefaults.standard.bool(forKey: "allowBattery") }
    set { UserDefaults.standard.set(newValue, forKey: "allowBattery") }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    runtimeDirectoryReady = prepareRuntimeDirectory()
    privilegedWorkerReady = privilegedWorkerIsSafe()
    buildMenu()
    configureStatusItem()
    refresh()
    refreshTimer = Timer.scheduledTimer(
      timeInterval: 1.0,
      target: self,
      selector: #selector(refresh),
      userInfo: nil,
      repeats: true)
  }

  private func prepareRuntimeDirectory() -> Bool {
    if Darwin.mkdir(runtimeDirectory, 0o700) != 0 && errno != EEXIST {
      showError("診断フォルダを準備できませんでした。", detail: posixErrorDescription())
      return false
    }

    let descriptor = Darwin.open(runtimeDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      showError(
        "診断フォルダを安全に開けませんでした。",
        detail: "シンボリックリンクや不正なフォルダがないか確認してください。\n\(posixErrorDescription())")
      return false
    }
    defer { Darwin.close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == uid
    else {
      showError(
        "診断フォルダの所有者が正しくありません。",
        detail: "安全のためCodex Lidを開始しません。\n\(runtimeDirectory)")
      return false
    }
    guard fchmod(descriptor, 0o700) == 0 else {
      showError("診断フォルダの権限を設定できませんでした。", detail: posixErrorDescription())
      return false
    }
    return true
  }

  private func buildMenu() {
    menu.delegate = self
    summaryItem.isEnabled = false
    remainingItem.isEnabled = false
    let actionItems = [
      start5Item, start30Item, start60Item, start120Item, batteryItem, stopItem, lockItem,
      emergencyResetItem,
    ]
    for item in actionItems {
      item.target = self
    }

    menu.addItem(summaryItem)
    menu.addItem(remainingItem)
    menu.addItem(.separator())
    menu.addItem(start5Item)
    menu.addItem(start30Item)
    menu.addItem(start60Item)
    menu.addItem(start120Item)
    menu.addItem(.separator())
    menu.addItem(batteryItem)
    menu.addItem(.separator())
    menu.addItem(stopItem)
    menu.addItem(lockItem)
    menu.addItem(emergencyResetItem)
    menu.addItem(.separator())

    let diagnosticsItem = NSMenuItem(
      title: "診断フォルダを開く", action: #selector(openDiagnosticsFolder), keyEquivalent: "")
    diagnosticsItem.target = self
    menu.addItem(diagnosticsItem)

    let aboutItem = NSMenuItem(
      title: "安全上の注意", action: #selector(showSafetyNotes), keyEquivalent: "")
    aboutItem.target = self
    menu.addItem(aboutItem)

    let quitItem = NSMenuItem(title: "Codex Lidを終了", action: #selector(quitApp), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)
  }

  private func configureStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.menu = menu
    updateIcon(active: false, warning: false)
  }

  func menuWillOpen(_ menu: NSMenu) {
    refresh()
  }

  @objc private func refresh() {
    privilegedWorkerReady = privilegedWorkerIsSafe()
    let status = readStatus()
    let sleepSetting = readSleepSetting()
    let sleepDisabled = sleepSetting == .enabled
    let workerRunning = status.map(statusRepresentsCurrentWorker) ?? false
    let workerActive = workerRunning && sleepDisabled
    let workerStarting =
      workerRunning && status?.state == "starting" && sleepSettingIsOff(sleepSetting)
    let warning = sleepDisabled && !workerRunning
    let settingUnknown = sleepSetting == .unknown

    if workerActive, let status {
      summaryItem.title =
        status.powerSource == "battery"
        ? "● 動作中（バッテリー \(status.batteryPercent)%）"
        : "● 動作中（電源接続）"
      let remaining = continuousSecondsRemaining(until: status.deadlineTicks)
      remainingItem.title =
        "残り \(formatDuration(remaining))・温度 \(localizedThermal(status.thermalState))"
    } else if workerStarting {
      summaryItem.title = "◌ 開始処理中…"
      remainingItem.title = "管理者監視を準備しています"
    } else if workerRunning {
      summaryItem.title = "◌ 停止処理中…"
      remainingItem.title = "通常スリープへの復旧を確認しています"
    } else if warning {
      summaryItem.title = "⚠︎ スリープ禁止が外部で有効です"
      remainingItem.title = "Codex Lidはこの設定を所有していません"
    } else if settingUnknown {
      summaryItem.title = "⚠︎ スリープ状態を確認できません"
      remainingItem.title = "安全のため新しいセッションを開始しません"
    } else if !privilegedWorkerReady {
      summaryItem.title = "⚠︎ インストールが必要です"
      remainingItem.title = "scripts/install.shを実行してください"
    } else if let status, ["stopped", "recovered", "error"].contains(status.state) {
      summaryItem.title = status.state == "error" ? "⚠︎ 開始できませんでした" : "○ 通常スリープ"
      remainingItem.title = localizedReason(status.reason)
    } else {
      summaryItem.title = "○ 通常スリープ"
      remainingItem.title = "蓋を閉じるとスリープします"
    }

    let canStart =
      runtimeDirectoryReady && privilegedWorkerReady && !workerRunning
      && sleepSettingIsOff(sleepSetting)
    start5Item.isEnabled = canStart
    start30Item.isEnabled = canStart
    start60Item.isEnabled = canStart
    start120Item.isEnabled = canStart
    batteryItem.isEnabled = !workerRunning
    batteryItem.state = allowBattery ? .on : .off
    stopItem.isEnabled = workerRunning
    emergencyResetItem.isHidden = !warning
    updateIcon(active: workerRunning, warning: warning || settingUnknown)
  }

  private func updateIcon(active: Bool, warning: Bool) {
    let symbol: String
    if warning {
      symbol = "exclamationmark.triangle.fill"
    } else if active {
      symbol = "bolt.circle.fill"
    } else {
      symbol = "moon.zzz"
    }
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Codex Lid")
    image?.isTemplate = true
    statusItem?.button?.image = image
    statusItem?.button?.toolTip = active ? "Codex Lid：蓋を閉じても動作中" : "Codex Lid：通常スリープ"
  }

  @objc private func start5() { startSession(minutes: 5) }
  @objc private func start30() { startSession(minutes: 30) }
  @objc private func start60() { startSession(minutes: 60) }
  @objc private func start120() { startSession(minutes: 120) }

  private func startSession(minutes: Int) {
    runtimeDirectoryReady = prepareRuntimeDirectory()
    guard runtimeDirectoryReady else { return }
    privilegedWorkerReady = privilegedWorkerIsSafe()
    guard privilegedWorkerReady else {
      showError(
        "保護された監視プログラムがありません。",
        detail: "このバージョンのscripts/install.shを実行してから、アプリを起動し直してください。")
      return
    }
    refresh()
    let sleepSetting = readSleepSetting()
    guard sleepSettingIsOff(sleepSetting) else {
      if sleepSetting == .unknown {
        showError("開始できません。", detail: "macOSのスリープ状態を確認できませんでした。")
        return
      }
      showError("開始できません。", detail: "別のツールがすでにスリープ禁止を有効にしています。先にそのツールを停止してください。")
      return
    }
    if !allowBattery && currentPowerSource() != "ac" {
      showError("電源アダプタを接続してください。", detail: "標準設定では、バッテリーだけで蓋閉じ動作を開始しません。")
      return
    }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "\(minutes)分間、蓋を閉じても動作を続けます"
    alert.informativeText =
      allowBattery
      ? "机など放熱できる場所に置いてください。バッグや布団の中では絶対に使わないでください。バッテリー25%または高温で自動停止します。"
      : "電源接続中だけ動作します。机など放熱できる場所に置き、バッグや布団の中では絶対に使わないでください。"
    alert.addButton(withTitle: "開始")
    alert.addButton(withTitle: "キャンセル")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    removeStaleRuntimeFiles()
    let sessionID = UUID().uuidString

    let arguments = [
      "--run",
      "--duration", String(minutes * 60),
      "--session", sessionID,
      "--uid", String(uid),
      "--status", statusPath,
      "--stop", stopPath,
      "--allow-battery", allowBattery ? "1" : "0",
      "--battery-floor", "25",
    ]
    let commandParts =
      [
        "/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "/usr/bin/nohup",
        privilegedWorkerPath,
      ] + arguments
    let command =
      commandParts.map(shellQuote).joined(separator: " ")
      + " > /dev/null 2>&1 < /dev/null &"

    var errorInfo: NSDictionary?
    let script = NSAppleScript(
      source: "do shell script \"\(appleScriptEscape(command))\" with administrator privileges")
    _ = script?.executeAndReturnError(&errorInfo)
    if let errorInfo {
      let number = errorInfo[NSAppleScript.errorNumber] as? Int
      if number != -128 {
        showError("開始できませんでした。", detail: errorInfo.description)
      }
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
  }

  @objc private func toggleBatteryMode() {
    allowBattery.toggle()
    refresh()
  }

  @objc private func stopSession() {
    guard let status = readStatus(), statusRepresentsCurrentWorker(status) else {
      refresh()
      return
    }
    do {
      try Data(status.sessionID.utf8).write(to: URL(fileURLWithPath: stopPath), options: .atomic)
      _ = Darwin.chmod(stopPath, 0o600)
      summaryItem.title = "停止処理中…"
    } catch {
      showError("停止要求を送れませんでした。", detail: error.localizedDescription)
    }
  }

  @objc private func lockScreen() {
    let lockStatus = runCapture("/usr/sbin/sysadminctl", ["-screenLock", "status"])
    if !lockStatus.lowercased().contains("immediate") {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "画面ロックが即時設定ではありません"
      alert.informativeText = "システム設定の「ロック画面」で、パスワード要求を即時にしてから使うことを推奨します。画面だけ消しますか？"
      alert.addButton(withTitle: "画面を消す")
      alert.addButton(withTitle: "キャンセル")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["displaysleepnow"]
    try? process.run()
  }

  @objc private func emergencyReset() {
    guard privilegedWorkerIsSafe() else {
      showError(
        "保護されたインストールから実行してください。",
        detail: "緊急時はターミナルで sudo pmset -a disablesleep 0 を実行できます。")
      return
    }

    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "スリープ設定を通常へ戻しますか？"
    alert.informativeText = "他のスリープ防止ツールが有効にした設定も解除されます。"
    alert.addButton(withTitle: "通常へ戻す")
    alert.addButton(withTitle: "キャンセル")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let resetParts = [
      "/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", privilegedWorkerPath,
      "--set-sleep", "0",
    ]
    let resetCommand =
      resetParts.map(shellQuote).joined(separator: " ")
      + " > /dev/null 2>&1 < /dev/null"
    var errorInfo: NSDictionary?
    let script = NSAppleScript(
      source:
        "do shell script \"\(appleScriptEscape(resetCommand))\" with administrator privileges")
    _ = script?.executeAndReturnError(&errorInfo)
    if let errorInfo {
      showError("復旧できませんでした。", detail: errorInfo.description)
    }
    refresh()
  }

  @objc private func openDiagnosticsFolder() {
    runtimeDirectoryReady = prepareRuntimeDirectory()
    guard runtimeDirectoryReady else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: runtimeDirectory, isDirectory: true))
  }

  @objc private func showSafetyNotes() {
    let alert = NSAlert()
    alert.messageText = "Codex Lidの安全上の注意"
    alert.informativeText =
      "・閉じたMacは通常スリープより多く電力を使います。\n・必ず硬く平らな場所で使ってください。\n・バッグ、ケース、布団の中では使用禁止です。\n・高温、低バッテリー、電源切断、タイマー終了で自動解除します。\n・pmset disablesleepはmacOSの非公開設定のため、OS更新後は短時間テストしてください。"
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  @objc private func quitApp() {
    if let status = readStatus(), statusRepresentsCurrentWorker(status) {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "セッションが動作中です"
      alert.informativeText = "アプリだけ終了しても、独立監視はタイマーまで動き続けます。"
      alert.addButton(withTitle: "停止して終了")
      alert.addButton(withTitle: "セッションを残して終了")
      alert.addButton(withTitle: "キャンセル")
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        stopSession()
        NSApp.terminate(nil)
      case .alertSecondButtonReturn:
        NSApp.terminate(nil)
      default:
        break
      }
    } else {
      NSApp.terminate(nil)
    }
  }

  private func readStatus() -> SessionStatus? {
    let descriptor = Darwin.open(statusPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_nlink == 1,
      info.st_uid == 0 || info.st_uid == uid,
      (info.st_mode & 0o022) == 0,
      info.st_size >= 0,
      info.st_size <= off_t(maximumStatusBytes)
    else { return nil }

    var data = Data()
    data.reserveCapacity(Int(info.st_size))
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count <= maximumStatusBytes {
      let requestedBytes = min(buffer.count, maximumStatusBytes + 1 - data.count)
      let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
        guard let baseAddress = rawBuffer.baseAddress else { return 0 }
        return Darwin.read(descriptor, baseAddress, requestedBytes)
      }
      if bytesRead < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if bytesRead == 0 { break }
      data.append(contentsOf: buffer[0..<bytesRead])
    }
    guard !data.isEmpty, data.count <= maximumStatusBytes else { return nil }
    return try? JSONDecoder().decode(SessionStatus.self, from: data)
  }

  private func readSleepSetting() -> SleepSettingState {
    let result = runCaptureResult("/usr/bin/pmset", ["-g"])
    guard result.0 == 0 else { return .unknown }
    for line in result.1.split(separator: "\n") {
      let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard fields.first?.lowercased() == "sleepdisabled" else { continue }
      switch fields.last {
      case "1": return .enabled
      case "0": return .disabled
      default: return .unknown
      }
    }
    return .absent
  }

  private func sleepSettingIsOff(_ state: SleepSettingState) -> Bool {
    state == .disabled || state == .absent
  }

  private func currentPowerSource() -> String {
    runCapture("/usr/bin/pmset", ["-g", "batt"]).contains("AC Power") ? "ac" : "battery"
  }

  private func processIsAlive(_ pid: Int32) -> Bool {
    guard pid > 1 else { return false }
    return Darwin.kill(pid, 0) == 0 || errno == EPERM
  }

  private func privilegedWorkerIsSafe() -> Bool {
    let directories = [
      "/Library",
      "/Library/Application Support",
      "/Library/Application Support/Codex Lid",
      protectedAppPath,
      protectedAppPath + "/Contents",
      protectedAppPath + "/Contents/MacOS",
      protectedAppPath + "/Contents/Resources",
    ]
    for path in directories {
      var info = stat()
      guard lstat(path, &info) == 0,
        (info.st_mode & S_IFMT) == S_IFDIR,
        info.st_uid == 0,
        (info.st_mode & 0o022) == 0,
        Darwin.access(path, W_OK) != 0
      else { return false }
    }

    guard let executablePath = Bundle.main.executablePath,
      canonicalPath(executablePath) == protectedAppPath + "/Contents/MacOS/Codex Lid"
    else { return false }

    for path in [executablePath, privilegedWorkerPath] {
      var info = stat()
      guard lstat(path, &info) == 0,
        (info.st_mode & S_IFMT) == S_IFREG,
        info.st_uid == 0,
        info.st_gid == 0,
        (info.st_mode & 0o022) == 0,
        (info.st_mode & (S_ISUID | S_ISGID)) == 0,
        info.st_nlink == 1,
        Darwin.access(path, W_OK) != 0,
        Darwin.access(path, X_OK) == 0
      else { return false }
    }
    return true
  }

  private func canonicalPath(_ path: String) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard Darwin.realpath(path, &buffer) != nil else { return nil }
    return String(cString: buffer)
  }

  private func statusRepresentsCurrentWorker(_ status: SessionStatus) -> Bool {
    let rootOwnedSession = try? String(contentsOfFile: activeSessionPath, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let nowTicks = mach_continuous_time()
    let (lifetimeSeconds, lifetimeOverflow) = status.expiresAt.subtractingReportingOverflow(
      status.startedAt)
    let (maximumDeadline, deadlineOverflow) = nowTicks.addingReportingOverflow(
      continuousTicks(forSeconds: 7_205))
    guard !lifetimeOverflow, !deadlineOverflow else { return false }
    let validLifetime =
      lifetimeSeconds >= 60
      && lifetimeSeconds <= 7200
      && status.deadlineTicks > nowTicks
      && status.deadlineTicks <= maximumDeadline
    return rootOwnedSession == status.sessionID
      && (status.state == "starting" || status.state == "active")
      && validLifetime
      && processIsAlive(status.pid)
  }

  private func continuousTicks(forSeconds seconds: Int) -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0 else {
      return UInt64(seconds) * UInt64(NSEC_PER_SEC)
    }
    let nanoseconds = UInt64(seconds) * UInt64(NSEC_PER_SEC)
    let numerator = UInt64(timebase.numer)
    let denominator = UInt64(timebase.denom)
    return (nanoseconds / numerator) * denominator
      + ((nanoseconds % numerator) * denominator) / numerator
  }

  private func continuousSecondsRemaining(until deadlineTicks: UInt64) -> Int64 {
    let nowTicks = mach_continuous_time()
    guard deadlineTicks > nowTicks else { return 0 }
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return 0 }
    let seconds =
      Double(deadlineTicks - nowTicks) * Double(timebase.numer) / Double(timebase.denom)
      / Double(NSEC_PER_SEC)
    return Int64(seconds.rounded(.down))
  }

  private func runCapture(_ executable: String, _ arguments: [String]) -> String {
    runCaptureResult(executable, arguments).1
  }

  private func runCaptureResult(_ executable: String, _ arguments: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    } catch {
      return (-1, "")
    }
  }

  private func removeStaleRuntimeFiles() {
    for path in [statusPath, stopPath] where FileManager.default.fileExists(atPath: path) {
      try? FileManager.default.removeItem(atPath: path)
    }
  }

  private func posixErrorDescription() -> String {
    String(cString: strerror(errno))
  }

  private func formatDuration(_ seconds: Int64) -> String {
    let minutes = seconds / 60
    let secs = seconds % 60
    return String(format: "%02lld:%02lld", minutes, secs)
  }

  private func localizedThermal(_ value: String) -> String {
    switch value {
    case "nominal": return "正常"
    case "fair": return "やや高め"
    case "serious": return "高温"
    case "critical": return "危険"
    default: return value
    }
  }

  private func localizedReason(_ value: String) -> String {
    switch value {
    case "timer-ended": return "タイマーが終了しました"
    case "manual-stop": return "手動で停止しました"
    case "ac-disconnected": return "電源が外れたため停止しました"
    case "battery-low": return "バッテリー低下で停止しました"
    case "low-power-mode": return "低電力モードで停止しました"
    case "power-source-unknown": return "電源状態を確認できないため停止しました"
    case "thermal-serious", "thermal-critical": return "高温を検知して停止しました"
    case "thermal-unknown": return "温度状態を確認できないため停止しました"
    case "watchdog-recovered": return "独立監視がスリープ設定を復旧しました"
    case "failsafe-stopped": return "独立監視を確認できず復旧しました"
    case "sleep-already-disabled": return "別のツールがスリープ禁止を使用中です"
    case "pmset-enable-verification-failed": return "スリープ設定を確認できず復旧しました"
    case "pmset-read-failed": return "スリープ状態を確認できず復旧しました"
    default: return value.isEmpty ? "" : value
    }
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func appleScriptEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  private func showError(_ message: String, detail: String) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = message
    alert.informativeText = detail
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}

@main
private enum CodexLidApp {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    objc_setAssociatedObject(app, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
  }
}

nonisolated(unsafe) private var delegateKey: UInt8 = 0
