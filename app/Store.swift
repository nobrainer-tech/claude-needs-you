// Part of the needs-you window; see main.swift.
import AppKit

// --- Brand -------------------------------------------------------------------

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
          blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
enum C {
  static let canvas = hex(0xF4F3EE), surface = hex(0xFFFCF7), ink = hex(0x202124)
  static let muted = hex(0x485162), border = hex(0xABB7CC), blue = hex(0x3B65F0)
  static let orange = hex(0xF04A14), rule = hex(0xD94724), label = hex(0xF7E8E1), labelText = hex(0x923018)
}
func registerFonts() {
  for name in ["Regular", "Medium", "SemiBold", "Bold", "ExtraBold"] {
    let url = URL(fileURLWithPath: assetsDir).appendingPathComponent("fonts/NoBrainerSans-\(name).ttf")
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
  }
}
func font(_ size: CGFloat, _ weight: String = "Regular") -> NSFont {
  NSFont(name: "NoBrainerSans-\(weight)", size: size) ?? .systemFont(ofSize: size)
}
func logo(_ name: String) -> NSImage? {
  NSImage(contentsOfFile: (assetsDir as NSString).appendingPathComponent("img/\(name)"))
}

// --- Data --------------------------------------------------------------------

struct Entry {
  let file, session, title, section, project, msg, link: String
  let ts, doneTs: TimeInterval
  let done: Bool
}

func readJSON(_ path: String) -> [String: Any]? {
  guard let d = FileManager.default.contents(atPath: path) else { return nil }
  return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}
func writeJSON(_ obj: [String: Any], _ path: String) {
  guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
  let tmp = path + ".tmp.\(getpid())"
  if FileManager.default.createFile(atPath: tmp, contents: d) { _ = rename(tmp, path) }
}
func num(_ v: Any?) -> TimeInterval { (v as? NSNumber)?.doubleValue ?? 0 }
func str(_ v: Any?) -> String { (v as? String) ?? "" }

// Waiting entries newest first, then handled ones, most recently handled first.
// Entries older than a day are removed.
func loadEntries() -> [Entry] {
  let fm = FileManager.default
  let now = Date().timeIntervalSince1970
  var out: [Entry] = []
  for name in (try? fm.contentsOfDirectory(atPath: inboxDir)) ?? [] where name.hasSuffix(".json") {
    let path = (inboxDir as NSString).appendingPathComponent(name)
    guard let j = readJSON(path) else { continue }
    let ts = num(j["ts"])
    if now - ts > dayAgo {
      withEntryLock(path) { if num(readJSON(path)?["ts"]) == ts { try? fm.removeItem(atPath: path) } }
      continue
    }
    out.append(Entry(file: path, session: str(j["session"]), title: str(j["title"]),
                     section: str(j["section"]), project: str(j["project"]), msg: str(j["msg"]),
                     link: str(j["link"]), ts: ts, doneTs: num(j["done_ts"]),
                     done: (j["done"] as? Bool) ?? false))
  }
  return out.sorted {
    if $0.done != $1.done { return !$0.done }
    return $0.done ? $0.doneTs > $1.doneTs : $0.ts > $1.ts
  }
}

// sessions: the sessions with their own autopilot on, id -> title.
struct Autopilot { var until: String?; var sessions: [String: String] }
func loadAutopilot() -> Autopilot {
  guard let j = readJSON(autopilotFile) else { return Autopilot(until: nil, sessions: [:]) }
  let now = Date().timeIntervalSince1970
  let u = num(j["until_epoch"])
  // A session is on while its last period has no end, for a day at most.
  let all = (j["sessions"] as? [String: [String: Any]]) ?? [:]
  let sessions = all.filter {
    guard let last = ($0.value["periods"] as? [[Any]])?.last, last.count == 2, last[1] is NSNull else { return false }
    return now - num(last[0]) < dayAgo
  }
    .mapValues { str($0["title"]) }
  return Autopilot(until: u > now && u - now <= dayAgo ? str(j["until"]) : nil, sessions: sessions)
}

// Every writer of an entry (the hook and this window) holds its lock folder, so
// a check and the write that follows it see the same request. A lock older than
// a minute belongs to a writer that crashed.
func withEntryLock(_ file: String, _ body: () -> Void) {
  let lock = file + ".lock"
  for _ in 0..<40 {
    if mkdir(lock, 0o700) == 0 { body(); rmdir(lock); return }
    if let m = (try? FileManager.default.attributesOfItem(atPath: lock))?[.modificationDate] as? Date,
       Date().timeIntervalSince(m) > 60 { rmdir(lock) }
    usleep(50_000)
  }
}

// Remove a handled entry, unless the session has asked again since. The time of
// the request stays in ../cleared/<session>, so needs-you-scan does not bring a
// question you cleared back.
func removeHandled(_ e: Entry) {
  withEntryLock(e.file) {
    guard let j = readJSON(e.file), (j["done"] as? Bool) == true, num(j["ts"]) == e.ts else { return }
    let cleared = ((inboxDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent("cleared")
    try? FileManager.default.createDirectory(atPath: cleared, withIntermediateDirectories: true)
    try? String(Int(e.ts)).write(toFile: (cleared as NSString).appendingPathComponent(e.session),
                                 atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(atPath: e.file)
  }
}

// Mark the request that was on screen handled; a newer one from the session stays.
func markDone(_ e: Entry) {
  withEntryLock(e.file) {
    guard var j = readJSON(e.file), (j["done"] as? Bool) != true, num(j["ts"]) == e.ts else { return }
    j["done"] = true
    j["done_ts"] = Int(Date().timeIntervalSince1970)
    writeJSON(j, e.file)
  }
}

func runAutopilot(_ arguments: [String]) {
  guard !autopilotCmd.isEmpty else { return }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: autopilotCmd)
  p.arguments = arguments
  try? p.run()
  p.waitUntilExit()
}

// Sessions that already wait (asked before the app was closed, or in a session
// that has not run since) come in through bin/needs-you-scan, next to
// nb-autopilot. It runs in the background; refresh() shows what it wrote.
func runScan() {
  guard !autopilotCmd.isEmpty else { return }
  let scan = ((autopilotCmd as NSString).deletingLastPathComponent as NSString).appendingPathComponent("needs-you-scan")
  guard FileManager.default.isExecutableFile(atPath: scan) else { return }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: scan)
  p.arguments = ["--no-open"]
  p.standardOutput = FileHandle.nullDevice
  p.standardError = FileHandle.nullDevice
  try? p.run()
}

func timeLabel(_ ts: TimeInterval) -> String {
  let d = Date(timeIntervalSince1970: ts)
  let f = DateFormatter()
  f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "dd.MM HH:mm"
  return f.string(from: d)
}
