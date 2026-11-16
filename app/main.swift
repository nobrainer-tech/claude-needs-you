// needs-you window (main.swift, with Store.swift and Views.swift): every Claude Code session that waits for you, in one window.
//
// The hook writes one JSON file per session to the inbox folder. This window
// shows them, waiting ones first (newest on top) and handled ones greyed out at
// the bottom. It refreshes in place and never takes focus after it opens.
// Clicking a session opens it in the Claude desktop app and marks it handled.
// A switch per session and a button for all sessions turn the autopilot on.
//
//   needs-you-window --inbox DIR --autopilot NB_AUTOPILOT --assets APP_DIR
//   needs-you-window ... --snapshot OUT.png    render once to a PNG and exit
//
// Texts come from NEEDS_YOU_* environment variables (see README). Typeface and
// colours: NoBrainer Sans and the NoBrainer Tech palette.
// https://github.com/nobrainer-tech/claude-needs-you
import AppKit

let env = ProcessInfo.processInfo.environment
func text(_ key: String, _ fallback: String) -> String {
  if let v = env[key], !v.isEmpty { return v }
  return fallback
}
let T = (
  title: text("NEEDS_YOU_TITLE", "Claude needs you"),
  empty: text("NEEDS_YOU_EMPTY", "No session is waiting for you."),
  hint: text("NEEDS_YOU_HINT", "Click a session to open it. Autopilot answers that session's questions with its own recommendation."),
  clear: text("NEEDS_YOU_CLEAR", "Clear handled"),
  rowAutopilot: text("NEEDS_YOU_ROW_AUTOPILOT", "Autopilot"),
  apStart: text("NEEDS_YOU_AP_START", "Autopilot until"),
  apStop: text("NEEDS_YOU_AP_STOP", "Stop autopilot"),
  apOn: text("NEEDS_YOU_AP_ON", "Autopilot on until"),
  apOff: text("NEEDS_YOU_AP_OFF", "Autopilot off"),
  waiting: text("NEEDS_YOU_WAITING_COUNT", "waiting"),
  handled: text("NEEDS_YOU_HANDLED", "handled")
)

var inboxDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/needs-you/inbox")
var autopilotCmd = ""
var assetsDir = ""
var snapshotPath: String?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
  switch a {
  case "--inbox": inboxDir = args.next() ?? inboxDir
  case "--autopilot": autopilotCmd = args.next() ?? ""
  case "--assets": assetsDir = args.next() ?? ""
  case "--snapshot": snapshotPath = args.next()
  default: break
  }
}
let dataDir = (inboxDir as NSString).deletingLastPathComponent
let autopilotFile = (dataDir as NSString).appendingPathComponent("autopilot.json")
let dayAgo: TimeInterval = 24 * 3600

registerFonts()
let app = NSApplication.shared

if let out = snapshotPath {
  app.setActivationPolicy(.prohibited)
  let inbox = Inbox()
  let v = inbox.window.contentView!
  v.layoutSubtreeIfNeeded()
  // Twice the point size, as on a Retina screen.
  guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width) * 2,
                                   pixelsHigh: Int(v.bounds.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
  rep.size = v.bounds.size
  v.cacheDisplay(in: v.bounds, to: rep)
  guard let png = rep.representation(using: .png, properties: [:]),
        FileManager.default.createFile(atPath: out, contents: png) else { exit(1) }
  exit(0)
}

// One window per user: a second copy exits at once.
try? FileManager.default.createDirectory(atPath: inboxDir, withIntermediateDirectories: true)
let lockFd = open((dataDir as NSString).appendingPathComponent("window.lock"), O_CREAT | O_RDWR, 0o600)
if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 { exit(0) }

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
