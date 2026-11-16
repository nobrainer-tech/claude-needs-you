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
    if now - ts > dayAgo { try? fm.removeItem(atPath: path); continue }
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

struct Autopilot { var until: String?; var sessions: Set<String> }
func loadAutopilot() -> Autopilot {
  guard let j = readJSON(autopilotFile) else { return Autopilot(until: nil, sessions: []) }
  let now = Date().timeIntervalSince1970
  let u = num(j["until_epoch"])
  let sessions = Set(((j["sessions"] as? [String: Any]) ?? [:]).keys)
  return Autopilot(until: u > now && u - now <= dayAgo ? str(j["until"]) : nil, sessions: sessions)
}

func markDone(_ e: Entry) {
  guard var j = readJSON(e.file), (j["done"] as? Bool) != true else { return }
  j["done"] = true
  j["done_ts"] = Int(Date().timeIntervalSince1970)
  writeJSON(j, e.file)
}

func runAutopilot(_ arguments: [String]) {
  guard !autopilotCmd.isEmpty else { return }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: autopilotCmd)
  p.arguments = arguments
  try? p.run()
  p.waitUntilExit()
}

func timeLabel(_ ts: TimeInterval) -> String {
  let d = Date(timeIntervalSince1970: ts)
  let f = DateFormatter()
  f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "dd.MM HH:mm"
  return f.string(from: d)
}
