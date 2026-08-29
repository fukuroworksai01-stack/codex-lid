import Darwin
import Foundation

private let lockPath = "/var/run/com.fukuroworks.codexlid.lock"
private let powerOperationLockPath = "/var/run/com.fukuroworks.codexlid.power.lock"
private let activePath = "/var/run/com.fukuroworks.codexlid.active"
private let readyPath = "/var/run/com.fukuroworks.codexlid.ready"
private let privilegedWorkerPath =
  "/Library/Application Support/Codex Lid/Codex Lid.app/Contents/Resources/CodexLidWorker"
private let statusFileName = "status.json"
private let stopFileName = "stop.request"

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

private struct BatteryStatus {
  let powerSource: String
  let percent: Int
}

private enum SleepSettingState: Equatable {
  case enabled
  case disabled
  case absent
  case unknown
}

private struct WorkerConfig {
  let duration: Int
  let sessionID: String
  let uid: uid_t
  let statusPath: String
  let stopPath: String
  let allowBattery: Bool
  let batteryFloor: Int
}

private final class StopFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false

  func requestStop() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
}

private enum WorkerError: Error, CustomStringConvertible {
  case invalidArguments(String)
  case unsafePath(String)
  case lockUnavailable
  case rootRequired
  case commandFailed(String)

  var description: String {
    switch self {
    case .invalidArguments(let value): return "invalid arguments: \(value)"
    case .unsafePath(let value): return "unsafe path: \(value)"
    case .lockUnavailable: return "another Codex Lid session is active"
    case .rootRequired: return "administrator privileges are required"
    case .commandFailed(let value): return "command failed: \(value)"
    }
  }
}

private func argumentValue(_ name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
    return nil
  }
  return arguments[index + 1]
}

private func parseConfig(_ arguments: [String]) throws -> WorkerConfig {
  guard let durationString = argumentValue("--duration", in: arguments),
    let duration = Int(durationString), (60...7200).contains(duration)
  else {
    throw WorkerError.invalidArguments("duration must be 60...7200 seconds")
  }
  guard let sessionID = argumentValue("--session", in: arguments),
    UUID(uuidString: sessionID) != nil
  else {
    throw WorkerError.invalidArguments("session must be a UUID")
  }
  guard let uidString = argumentValue("--uid", in: arguments), let uid = uid_t(uidString) else {
    throw WorkerError.invalidArguments("uid is missing")
  }
  guard let statusPath = argumentValue("--status", in: arguments),
    let stopPath = argumentValue("--stop", in: arguments)
  else {
    throw WorkerError.invalidArguments("runtime paths are missing")
  }
  let allowBattery = argumentValue("--allow-battery", in: arguments) == "1"
  guard let floorString = argumentValue("--battery-floor", in: arguments),
    let batteryFloor = Int(floorString), (10...50).contains(batteryFloor)
  else {
    throw WorkerError.invalidArguments("battery floor must be 10...50")
  }
  try validateRuntimePath(statusPath, expectedFileName: statusFileName, uid: uid)
  try validateRuntimePath(stopPath, expectedFileName: stopFileName, uid: uid)
  return WorkerConfig(
    duration: duration,
    sessionID: sessionID,
    uid: uid,
    statusPath: statusPath,
    stopPath: stopPath,
    allowBattery: allowBattery,
    batteryFloor: batteryFloor)
}

private func runtimeDirectoryPath(uid: uid_t) -> String {
  "/private/tmp/codex-lid-\(uid)"
}

private func validateRuntimePath(_ path: String, expectedFileName: String, uid: uid_t) throws {
  let root = "/private/tmp/codex-lid-\(uid)"
  let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
  guard normalized == root + "/" + expectedFileName else {
    throw WorkerError.unsafePath(path)
  }
}

private func validatePrivilegedExecutable() throws {
  let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
  guard executablePath == privilegedWorkerPath else {
    throw WorkerError.unsafePath("worker must run from its protected installation path")
  }

  for path in [
    "/Library",
    "/Library/Application Support",
    "/Library/Application Support/Codex Lid",
    "/Library/Application Support/Codex Lid/Codex Lid.app",
    "/Library/Application Support/Codex Lid/Codex Lid.app/Contents",
    "/Library/Application Support/Codex Lid/Codex Lid.app/Contents/Resources",
  ] {
    var info = stat()
    guard lstat(path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == 0,
      (info.st_mode & 0o022) == 0
    else { throw WorkerError.unsafePath(path) }
  }

  var workerInfo = stat()
  guard lstat(privilegedWorkerPath, &workerInfo) == 0,
    (workerInfo.st_mode & S_IFMT) == S_IFREG,
    workerInfo.st_uid == 0,
    workerInfo.st_gid == 0,
    (workerInfo.st_mode & 0o022) == 0,
    (workerInfo.st_mode & (S_ISUID | S_ISGID)) == 0,
    workerInfo.st_nlink == 1
  else { throw WorkerError.unsafePath(privilegedWorkerPath) }
}

private func openRuntimeDirectory(uid: uid_t) throws -> Int32 {
  let root = runtimeDirectoryPath(uid: uid)
  let descriptor = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard descriptor >= 0 else { throw WorkerError.unsafePath(root) }
  var info = stat()
  guard fstat(descriptor, &info) == 0,
    (info.st_mode & S_IFMT) == S_IFDIR,
    info.st_uid == uid,
    (info.st_mode & 0o077) == 0
  else {
    Darwin.close(descriptor)
    throw WorkerError.unsafePath(root)
  }
  return descriptor
}

private func acquireSessionLock() throws -> Int32 {
  let fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
  guard fd >= 0 else { throw WorkerError.lockUnavailable }
  var info = stat()
  guard fstat(fd, &info) == 0,
    (info.st_mode & S_IFMT) == S_IFREG,
    info.st_uid == 0
  else {
    Darwin.close(fd)
    throw WorkerError.unsafePath(lockPath)
  }
  guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
    Darwin.close(fd)
    throw WorkerError.lockUnavailable
  }
  return fd
}

private func acquirePowerOperationLockForExec() throws -> Int32 {
  // This descriptor intentionally survives exec. The pmset process itself
  // holds the lock, so a reset cannot overtake an orphaned enable operation.
  let fd = Darwin.open(powerOperationLockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
  guard fd >= 0 else {
    throw WorkerError.commandFailed("could not open the power-operation lock")
  }

  var info = stat()
  guard fstat(fd, &info) == 0,
    (info.st_mode & S_IFMT) == S_IFREG,
    info.st_uid == 0,
    info.st_nlink == 1,
    Darwin.fchown(fd, 0, 0) == 0,
    Darwin.fchmod(fd, 0o600) == 0
  else {
    Darwin.close(fd)
    throw WorkerError.unsafePath(powerOperationLockPath)
  }

  guard flock(fd, LOCK_EX) == 0 else {
    Darwin.close(fd)
    throw WorkerError.commandFailed("could not lock the power operation")
  }
  let descriptorFlags = fcntl(fd, F_GETFD)
  guard descriptorFlags >= 0,
    fcntl(fd, F_SETFD, descriptorFlags & ~FD_CLOEXEC) == 0
  else {
    Darwin.close(fd)
    throw WorkerError.commandFailed("could not preserve the power-operation lock")
  }
  return fd
}

@discardableResult
private func runCommand(_ executable: String, _ arguments: [String]) -> (Int32, String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  do {
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
  } catch {
    return (-1, error.localizedDescription)
  }
}

private func runSerializedSleepCommand(_ enabled: Bool) -> Int32 {
  guard geteuid() == 0 else { return -1 }
  let lockFD: Int32
  do {
    lockFD = try acquirePowerOperationLockForExec()
  } catch {
    return -1
  }

  let executable = "/usr/bin/pmset"
  var cArguments: [UnsafeMutablePointer<CChar>?] = [
    strdup("pmset"), strdup("-a"), strdup("disablesleep"), strdup(enabled ? "1" : "0"),
    nil,
  ]
  var childPID: pid_t = 0
  let spawnResult = cArguments.withUnsafeMutableBufferPointer { buffer in
    Darwin.posix_spawn(&childPID, executable, nil, nil, buffer.baseAddress, environ)
  }
  if spawnResult != 0 {
    for case let pointer? in cArguments { free(pointer) }
    Darwin.close(lockFD)
    return -1
  }

  // The child inherited the same locked open-file description. Closing this
  // copy means an orphaned pmset still holds the lock until it exits.
  Darwin.close(lockFD)
  for case let pointer? in cArguments { free(pointer) }

  var childStatus: Int32 = 0
  while Darwin.waitpid(childPID, &childStatus, 0) < 0 {
    if errno == EINTR { continue }
    return -1
  }
  guard (childStatus & 0x7f) == 0 else { return -1 }
  return (childStatus >> 8) & 0xff
}

private func testSpawnedProcessRetainsLock() -> Bool {
  var template = Array("/private/tmp/codex-lid-lock-selftest.XXXXXX".utf8CString)
  let lockFD = template.withUnsafeMutableBufferPointer { buffer in
    Darwin.mkstemp(buffer.baseAddress)
  }
  guard lockFD >= 0 else { return false }
  let path = String(cString: template)
  defer { _ = Darwin.unlink(path) }

  guard Darwin.fchmod(lockFD, 0o600) == 0,
    flock(lockFD, LOCK_EX) == 0
  else {
    Darwin.close(lockFD)
    return false
  }
  let descriptorFlags = Darwin.fcntl(lockFD, F_GETFD)
  guard descriptorFlags >= 0,
    Darwin.fcntl(lockFD, F_SETFD, descriptorFlags & ~FD_CLOEXEC) == 0
  else {
    Darwin.close(lockFD)
    return false
  }

  var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("1"), nil]
  var childPID: pid_t = 0
  let spawnResult = arguments.withUnsafeMutableBufferPointer { buffer in
    Darwin.posix_spawn(&childPID, "/bin/sleep", nil, nil, buffer.baseAddress, environ)
  }
  for case let pointer? in arguments { free(pointer) }
  guard spawnResult == 0 else {
    Darwin.close(lockFD)
    return false
  }

  Darwin.close(lockFD)
  let contenderFD = Darwin.open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
  guard contenderFD >= 0 else {
    var childStatus: Int32 = 0
    _ = Darwin.waitpid(childPID, &childStatus, 0)
    return false
  }

  let earlyLockResult = flock(contenderFD, LOCK_EX | LOCK_NB)
  let earlyLockError = errno
  if earlyLockResult == 0 { _ = flock(contenderFD, LOCK_UN) }

  var childStatus: Int32 = 0
  let waitedPID = Darwin.waitpid(childPID, &childStatus, 0)
  let lateLockResult = flock(contenderFD, LOCK_EX | LOCK_NB)
  if lateLockResult == 0 { _ = flock(contenderFD, LOCK_UN) }
  Darwin.close(contenderFD)

  let childSucceeded =
    waitedPID == childPID && (childStatus & 0x7f) == 0
    && ((childStatus >> 8) & 0xff) == 0
  return earlyLockResult < 0
    && (earlyLockError == EWOULDBLOCK || earlyLockError == EAGAIN)
    && lateLockResult == 0 && childSucceeded
}

private func runSetSleep(_ arguments: [String]) throws -> Int32 {
  guard geteuid() == 0 else { throw WorkerError.rootRequired }
  try validatePrivilegedExecutable()
  guard arguments.count == 2,
    arguments[0] == "--set-sleep",
    arguments[1] == "0"
  else {
    throw WorkerError.invalidArguments("set-sleep only accepts the recovery value 0")
  }

  return runSerializedSleepCommand(false)
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

private func continuousDeadline(afterSeconds seconds: Int) throws -> UInt64 {
  let (deadline, overflow) = mach_continuous_time().addingReportingOverflow(
    continuousTicks(forSeconds: seconds))
  guard !overflow else { throw WorkerError.invalidArguments("duration overflow") }
  return deadline
}

private func setSleepDisabled(_ enabled: Bool) -> Bool {
  runSerializedSleepCommand(enabled) == 0
}

private func resetSleepSetting() -> Bool {
  _ = setSleepDisabled(false)
  return sleepSettingIsOff(readSleepSetting())
}

private func parseSleepSetting(_ output: String) -> SleepSettingState {
  for line in output.split(separator: "\n") {
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

private func readSleepSetting() -> SleepSettingState {
  let result = runCommand("/usr/bin/pmset", ["-g"])
  guard result.0 == 0 else { return .unknown }
  return parseSleepSetting(result.1)
}

private func sleepSettingIsOff(_ state: SleepSettingState) -> Bool {
  state == .disabled || state == .absent
}

private func parseBattery(_ output: String) -> BatteryStatus {
  let source: String
  if output.contains("AC Power") {
    source = "ac"
  } else if output.contains("Battery Power") {
    source = "battery"
  } else {
    source = "unknown"
  }
  let regex = try? NSRegularExpression(pattern: "([0-9]{1,3})%")
  let range = NSRange(output.startIndex..<output.endIndex, in: output)
  var percent = -1
  if let match = regex?.firstMatch(in: output, range: range),
    let valueRange = Range(match.range(at: 1), in: output),
    let value = Int(output[valueRange]), (0...100).contains(value)
  {
    percent = value
  }
  return BatteryStatus(powerSource: source, percent: percent)
}

private func currentBattery() -> BatteryStatus {
  let result = runCommand("/usr/bin/pmset", ["-g", "batt"])
  guard result.0 == 0 else { return BatteryStatus(powerSource: "unknown", percent: -1) }
  return parseBattery(result.1)
}

private func thermalState() -> String {
  switch ProcessInfo.processInfo.thermalState {
  case .nominal: return "nominal"
  case .fair: return "fair"
  case .serious: return "serious"
  case .critical: return "critical"
  @unknown default: return "unknown"
  }
}

private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
  data.withUnsafeBytes { buffer in
    guard let baseAddress = buffer.baseAddress else { return data.isEmpty }
    var offset = 0
    while offset < data.count {
      let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), data.count - offset)
      if written < 0 {
        if errno == EINTR { continue }
        return false
      }
      if written == 0 { return false }
      offset += written
    }
    return true
  }
}

private func writeStatus(_ status: SessionStatus, directoryFD: Int32) {
  guard let data = try? JSONEncoder().encode(status) else { return }
  let descriptor = Darwin.openat(
    directoryFD,
    statusFileName,
    O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
    0o644)
  guard descriptor >= 0 else { return }
  defer { Darwin.close(descriptor) }

  var info = stat()
  guard fstat(descriptor, &info) == 0,
    (info.st_mode & S_IFMT) == S_IFREG,
    info.st_nlink == 1,
    Darwin.ftruncate(descriptor, 0) == 0
  else { return }
  _ = Darwin.fchmod(descriptor, 0o644)
  _ = writeAll(data, to: descriptor)
  // Status is diagnostic only. Safety decisions never depend on this write.
}

private func safeRootOwnedRegularFile(_ path: String) -> Bool {
  var info = stat()
  if lstat(path, &info) != 0 { return errno == ENOENT }
  return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == 0
    && (info.st_mode & 0o022) == 0 && info.st_nlink == 1
}

private func writeRootOwnedToken(_ value: String, to path: String, mode: mode_t) throws {
  guard safeRootOwnedRegularFile(path) else { throw WorkerError.unsafePath(path) }
  try Data(value.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
  guard Darwin.chmod(path, mode) == 0, Darwin.chown(path, 0, 0) == 0 else {
    _ = unlink(path)
    throw WorkerError.commandFailed("could not secure root coordination file")
  }
}

private func rootOwnedToken(at path: String) -> String? {
  guard safeRootOwnedRegularFile(path),
    let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 128
  else { return nil }
  return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func writeActiveSession(_ sessionID: String) throws {
  try writeRootOwnedToken(sessionID, to: activePath, mode: 0o644)
}

private func activeSession() -> String? {
  rootOwnedToken(at: activePath)
}

private func removeActiveSession(ifOwnedBy sessionID: String) {
  guard activeSession() == sessionID else { return }
  _ = unlink(activePath)
}

private func writeReadySession(_ sessionID: String) throws {
  try writeRootOwnedToken(sessionID, to: readyPath, mode: 0o600)
}

private func readySession() -> String? {
  rootOwnedToken(at: readyPath)
}

private func removeReadySession(ifOwnedBy sessionID: String) {
  guard readySession() == sessionID else { return }
  _ = unlink(readyPath)
}

private func clearReadySession() throws {
  var info = stat()
  if lstat(readyPath, &info) != 0 {
    if errno == ENOENT { return }
    throw WorkerError.unsafePath(readyPath)
  }
  guard safeRootOwnedRegularFile(readyPath), unlink(readyPath) == 0 else {
    throw WorkerError.unsafePath(readyPath)
  }
}

private func stopWasRequested(directoryFD: Int32, uid: uid_t, sessionID: String) -> Bool {
  let descriptor = Darwin.openat(
    directoryFD, stopFileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  guard descriptor >= 0 else { return false }
  defer { Darwin.close(descriptor) }

  var info = stat()
  guard fstat(descriptor, &info) == 0,
    (info.st_mode & S_IFMT) == S_IFREG,
    info.st_uid == uid,
    info.st_nlink == 1,
    info.st_size > 0,
    info.st_size <= 128
  else { return false }

  var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
  let count = bytes.withUnsafeMutableBytes { buffer in
    Darwin.read(descriptor, buffer.baseAddress, buffer.count)
  }
  guard count > 0 else { return false }
  let value = String(decoding: bytes.prefix(Int(count)), as: UTF8.self)
  return value.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID
}

private func processIsAlive(_ pid: Int32) -> Bool {
  guard pid > 1 else { return false }
  return Darwin.kill(pid, 0) == 0 || errno == EPERM
}

private func spawnFailsafe(
  sessionID: String,
  workerPID: Int32,
  deadlineTicks: UInt64,
  expiresAt: Int64,
  statusPath: String,
  uid: uid_t
) throws -> Process {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: privilegedWorkerPath)
  process.arguments = [
    "--failsafe",
    "--session", sessionID,
    "--worker-pid", String(workerPID),
    "--deadline-ticks", String(deadlineTicks),
    "--expires-at", String(expiresAt),
    "--status", statusPath,
    "--uid", String(uid),
  ]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  process.standardInput = FileHandle.nullDevice
  try process.run()
  return process
}

private func waitForFailsafeReady(sessionID: String, process: Process) -> Bool {
  let waitDeadline = mach_continuous_time() + continuousTicks(forSeconds: 5)
  while mach_continuous_time() < waitDeadline {
    if readySession() == sessionID { return true }
    if !process.isRunning { return false }
    Thread.sleep(forTimeInterval: 0.05)
  }
  return readySession() == sessionID
}

private func installSignalHandlers(_ flag: StopFlag) -> [DispatchSourceSignal] {
  [SIGTERM, SIGINT, SIGHUP].map { signalNumber in
    Darwin.signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(
      signal: signalNumber, queue: .global(qos: .utility))
    source.setEventHandler { flag.requestStop() }
    source.resume()
    return source
  }
}

private func runWorker(_ config: WorkerConfig) throws -> Int32 {
  guard geteuid() == 0 else { throw WorkerError.rootRequired }
  try validatePrivilegedExecutable()
  let runtimeDirectoryFD = try openRuntimeDirectory(uid: config.uid)
  defer { Darwin.close(runtimeDirectoryFD) }
  let lockFD = try acquireSessionLock()
  defer {
    _ = flock(lockFD, LOCK_UN)
    Darwin.close(lockFD)
  }

  let startedAt = Int64(Date().timeIntervalSince1970)
  let expiresAt = startedAt + Int64(config.duration)
  let deadlineTicks = try continuousDeadline(afterSeconds: config.duration)
  let pid = getpid()
  var ownsSleepSetting = false
  var cleanupCompleted = false
  let signalFlag = StopFlag()
  let signalSources = installSignalHandlers(signalFlag)
  _ = signalSources

  func status(_ state: String, _ reason: String) {
    let battery = currentBattery()
    writeStatus(
      SessionStatus(
        sessionID: config.sessionID,
        state: state,
        reason: reason,
        startedAt: startedAt,
        expiresAt: expiresAt,
        deadlineTicks: deadlineTicks,
        powerSource: battery.powerSource,
        batteryPercent: battery.percent,
        thermalState: thermalState(),
        pid: pid),
      directoryFD: runtimeDirectoryFD)
  }

  defer {
    if ownsSleepSetting && !cleanupCompleted {
      if resetSleepSetting() {
        removeActiveSession(ifOwnedBy: config.sessionID)
      }
    }
  }

  status("starting", "")
  let initialSleepSetting = readSleepSetting()
  if initialSleepSetting == .enabled {
    status("error", "sleep-already-disabled")
    return 4
  }
  guard sleepSettingIsOff(initialSleepSetting) else {
    status("error", "pmset-read-failed")
    return 4
  }

  let initialBattery = currentBattery()
  guard initialBattery.powerSource != "unknown", initialBattery.percent >= 0 else {
    status("error", "power-source-unknown")
    return 4
  }
  if initialBattery.powerSource == "battery" && !config.allowBattery {
    status("error", "ac-disconnected")
    return 4
  }
  let initialThermal = thermalState()
  guard initialThermal == "nominal" || initialThermal == "fair" else {
    status("error", "thermal-\(initialThermal)")
    return 4
  }

  try writeActiveSession(config.sessionID)
  let failsafe: Process
  do {
    try clearReadySession()
    failsafe = try spawnFailsafe(
      sessionID: config.sessionID,
      workerPID: pid,
      deadlineTicks: deadlineTicks,
      expiresAt: expiresAt,
      statusPath: config.statusPath,
      uid: config.uid)
    guard waitForFailsafeReady(sessionID: config.sessionID, process: failsafe) else {
      removeActiveSession(ifOwnedBy: config.sessionID)
      removeReadySession(ifOwnedBy: config.sessionID)
      throw WorkerError.commandFailed("failsafe did not become ready")
    }
    removeReadySession(ifOwnedBy: config.sessionID)
  } catch {
    removeActiveSession(ifOwnedBy: config.sessionID)
    removeReadySession(ifOwnedBy: config.sessionID)
    throw WorkerError.commandFailed("could not start failsafe: \(error.localizedDescription)")
  }

  guard failsafe.isRunning else {
    status("error", "failsafe-stopped")
    return 5
  }
  let enableCommandSucceeded = setSleepDisabled(true)
  // Once an enable was attempted, assume ownership until a verified reset.
  // pmset can change the setting even when the command exits unsuccessfully.
  ownsSleepSetting = true
  guard enableCommandSucceeded else {
    status("error", "pmset-enable-failed")
    return 5
  }
  guard readSleepSetting() == .enabled else {
    status("error", "pmset-enable-verification-failed")
    return 5
  }
  guard failsafe.isRunning else {
    status("error", "failsafe-stopped")
    return 5
  }

  var stopReason = "timer-ended"
  while mach_continuous_time() < deadlineTicks {
    let battery = currentBattery()
    let thermal = thermalState()

    if signalFlag.isStopped {
      stopReason = "signal-stop"
      break
    }
    if !failsafe.isRunning {
      stopReason = "failsafe-stopped"
      break
    }
    if stopWasRequested(
      directoryFD: runtimeDirectoryFD, uid: config.uid, sessionID: config.sessionID)
    {
      stopReason = "manual-stop"
      break
    }
    if battery.powerSource == "unknown" || battery.percent < 0 {
      stopReason = "power-source-unknown"
      break
    }
    if battery.powerSource == "battery" && !config.allowBattery {
      stopReason = "ac-disconnected"
      break
    }
    if battery.powerSource == "battery" && battery.percent <= config.batteryFloor {
      stopReason = "battery-low"
      break
    }
    if battery.powerSource == "battery" && ProcessInfo.processInfo.isLowPowerModeEnabled {
      stopReason = "low-power-mode"
      break
    }
    if thermal == "serious" || thermal == "critical" || thermal == "unknown" {
      stopReason = "thermal-\(thermal)"
      break
    }
    let sleepSetting = readSleepSetting()
    if sleepSetting == .disabled {
      stopReason = "setting-cleared-externally"
      ownsSleepSetting = false
      removeActiveSession(ifOwnedBy: config.sessionID)
      cleanupCompleted = true
      status("stopped", stopReason)
      return 0
    }
    if sleepSetting == .absent || sleepSetting == .unknown {
      stopReason = "pmset-read-failed"
      break
    }

    status("active", "")
    Thread.sleep(forTimeInterval: 5)
  }

  let resetSucceeded = resetSleepSetting()
  if resetSucceeded {
    ownsSleepSetting = false
    cleanupCompleted = true
    removeActiveSession(ifOwnedBy: config.sessionID)
    status("stopped", stopReason)
    return 0
  }

  status("error", "pmset-reset-failed")
  return 6
}

private func runFailsafe(_ arguments: [String]) throws -> Int32 {
  guard geteuid() == 0 else { throw WorkerError.rootRequired }
  try validatePrivilegedExecutable()
  guard let sessionID = argumentValue("--session", in: arguments),
    UUID(uuidString: sessionID) != nil,
    let pidString = argumentValue("--worker-pid", in: arguments), let workerPID = Int32(pidString),
    workerPID > 1,
    let deadlineString = argumentValue("--deadline-ticks", in: arguments),
    let deadlineTicks = UInt64(deadlineString),
    let expiresAtString = argumentValue("--expires-at", in: arguments),
    let expiresAt = Int64(expiresAtString),
    let statusPath = argumentValue("--status", in: arguments),
    let uidString = argumentValue("--uid", in: arguments), let uid = uid_t(uidString)
  else {
    throw WorkerError.invalidArguments("failsafe arguments")
  }
  try validateRuntimePath(statusPath, expectedFileName: statusFileName, uid: uid)
  let maximumDeadline = mach_continuous_time() + continuousTicks(forSeconds: 7_205)
  guard deadlineTicks <= maximumDeadline else {
    throw WorkerError.invalidArguments("failsafe deadline is too far in the future")
  }
  let runtimeDirectoryFD = try? openRuntimeDirectory(uid: uid)
  defer {
    if let runtimeDirectoryFD { Darwin.close(runtimeDirectoryFD) }
  }

  guard activeSession() == sessionID else { return 0 }
  try writeReadySession(sessionID)
  defer { removeReadySession(ifOwnedBy: sessionID) }
  let resetDeadline = deadlineTicks

  while activeSession() == sessionID {
    let nowTicks = mach_continuous_time()
    if !processIsAlive(workerPID) {
      let reset = resetSleepSetting()
      if reset {
        removeActiveSession(ifOwnedBy: sessionID)
        let battery = currentBattery()
        if let runtimeDirectoryFD {
          writeStatus(
            SessionStatus(
              sessionID: sessionID,
              state: "recovered",
              reason: "watchdog-recovered",
              startedAt: Int64(Date().timeIntervalSince1970),
              expiresAt: expiresAt,
              deadlineTicks: deadlineTicks,
              powerSource: battery.powerSource,
              batteryPercent: battery.percent,
              thermalState: thermalState(),
              pid: getpid()),
            directoryFD: runtimeDirectoryFD)
        }
        return 0
      }
    }
    if nowTicks > resetDeadline {
      if resetSleepSetting() {
        // Do not signal workerPID here: a stale PID may have been reused by
        // an unrelated process. The worker lock remains authoritative.
        removeActiveSession(ifOwnedBy: sessionID)
        return 0
      }
    }
    Thread.sleep(forTimeInterval: 2)
  }
  return 0
}

private func runSelfTest() -> Int32 {
  var failures: [String] = []
  if parseSleepSetting("System-wide power settings:\n SleepDisabled 1\n") != .enabled {
    failures.append("SleepDisabled=1 parser")
  }
  if parseSleepSetting("System-wide power settings:\n SleepDisabled 0\n") != .disabled {
    failures.append("SleepDisabled=0 parser")
  }
  if parseSleepSetting("System-wide power settings:\n") != .absent {
    failures.append("SleepDisabled absent parser")
  }
  if parseSleepSetting("SleepDisabled unavailable\n") != .unknown {
    failures.append("SleepDisabled malformed parser")
  }
  if parseSleepSetting("NotSleepDisabled 1\n") != .absent {
    failures.append("SleepDisabled exact-key parser")
  }

  let ac = parseBattery("Now drawing from 'AC Power'\n -InternalBattery-0 95%; charged;")
  if ac.powerSource != "ac" || ac.percent != 95 { failures.append("AC battery parser") }
  let battery = parseBattery(
    "Now drawing from 'Battery Power'\n -InternalBattery-0 24%; discharging;")
  if battery.powerSource != "battery" || battery.percent != 24 { failures.append("battery parser") }
  let unknown = parseBattery("power source unavailable")
  if unknown.powerSource != "unknown" || unknown.percent != -1 {
    failures.append("unknown power parser")
  }
  let invalidPercent = parseBattery(
    "Now drawing from 'Battery Power'\n -InternalBattery-0 999%; discharging;")
  if invalidPercent.percent != -1 { failures.append("out-of-range battery parser") }
  if continuousTicks(forSeconds: 1) == 0 { failures.append("continuous clock conversion") }
  if !testSpawnedProcessRetainsLock() { failures.append("power-operation lock inheritance") }

  do {
    try validateRuntimePath(
      "/private/tmp/codex-lid-501/status.json", expectedFileName: statusFileName, uid: 501)
  } catch {
    failures.append("valid runtime path")
  }
  do {
    try validateRuntimePath(
      "/private/tmp/codex-lid-501/../status.json", expectedFileName: statusFileName, uid: 501)
    failures.append("unsafe runtime path")
  } catch {
    // Expected.
  }

  let sample = SessionStatus(
    sessionID: UUID().uuidString,
    state: "active",
    reason: "",
    startedAt: 1,
    expiresAt: 2,
    deadlineTicks: 3,
    powerSource: "ac",
    batteryPercent: 100,
    thermalState: "nominal",
    pid: 123)
  if (try? JSONEncoder().encode(sample)) == nil { failures.append("status JSON") }

  if failures.isEmpty {
    print("CodexLidWorker self-test: PASS")
    return 0
  }
  fputs("CodexLidWorker self-test: FAIL: \(failures.joined(separator: ", "))\n", stderr)
  return 1
}

private func main() -> Int32 {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments.contains("--self-test") {
    return runSelfTest()
  }
  do {
    if arguments.contains("--run") {
      return try runWorker(parseConfig(arguments))
    }
    if arguments.contains("--failsafe") {
      return try runFailsafe(arguments)
    }
    if arguments.first == "--set-sleep" {
      return try runSetSleep(arguments)
    }
    fputs(
      "Usage: CodexLidWorker --run ... | --failsafe ... | --set-sleep 0 | --self-test\n",
      stderr)
    return 2
  } catch {
    fputs("CodexLidWorker: \(error)\n", stderr)
    return 3
  }
}

Darwin.exit(main())
