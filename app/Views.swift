// Part of the needs-you window; see main.swift.
import AppKit

// --- Views -------------------------------------------------------------------

func label(_ s: String, _ f: NSFont, _ color: NSColor, lines: Int = 1) -> NSTextField {
  let l = NSTextField(wrappingLabelWithString: s)
  l.font = f
  l.textColor = color
  l.maximumNumberOfLines = lines
  l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
  l.cell?.truncatesLastVisibleLine = true
  l.isSelectable = false
  return l
}

final class Target: NSObject {
  let f: () -> Void
  init(_ f: @escaping () -> Void) { self.f = f }
  @objc func fire() { f() }
}

// A flat brand button: blue fill with white text, or an outline.
func pill(_ title: String, filled: Bool, size: CGFloat = 13, _ action: Target) -> NSButton {
  let b = NSButton(title: "", target: action, action: #selector(Target.fire))
  b.isBordered = false
  b.wantsLayer = true
  b.layer?.cornerRadius = 7
  b.layer?.backgroundColor = (filled ? C.blue : .clear).cgColor
  b.layer?.borderColor = C.blue.cgColor
  b.layer?.borderWidth = filled ? 0 : 1.2
  b.attributedTitle = NSAttributedString(string: "  \(title)  ", attributes: [
    .font: font(size, "SemiBold"), .foregroundColor: filled ? NSColor.white : C.blue])
  objc_setAssociatedObject(b, "t", action, .OBJC_ASSOCIATION_RETAIN)
  b.heightAnchor.constraint(equalToConstant: size + 13).isActive = true
  return b
}

// The brand corner: large radius top-left and bottom-right, small elsewhere.
class Card: NSView {
  var fill = C.surface, stroke: NSColor? = C.border, accent: NSColor?
  override var isFlipped: Bool { true }
  override func draw(_ r: NSRect) {
    let b = bounds.insetBy(dx: 0.5, dy: 0.5), big: CGFloat = 16, small: CGFloat = 5
    let p = NSBezierPath()
    p.move(to: NSPoint(x: b.minX + big, y: b.minY))
    p.line(to: NSPoint(x: b.maxX - small, y: b.minY))
    p.appendArc(withCenter: NSPoint(x: b.maxX - small, y: b.minY + small), radius: small, startAngle: 270, endAngle: 0)
    p.line(to: NSPoint(x: b.maxX, y: b.maxY - big))
    p.appendArc(withCenter: NSPoint(x: b.maxX - big, y: b.maxY - big), radius: big, startAngle: 0, endAngle: 90)
    p.line(to: NSPoint(x: b.minX + small, y: b.maxY))
    p.appendArc(withCenter: NSPoint(x: b.minX + small, y: b.maxY - small), radius: small, startAngle: 90, endAngle: 180)
    p.line(to: NSPoint(x: b.minX, y: b.minY + big))
    p.appendArc(withCenter: NSPoint(x: b.minX + big, y: b.minY + big), radius: big, startAngle: 180, endAngle: 270)
    p.close()
    fill.setFill(); p.fill()
    if let s = stroke { s.setStroke(); p.lineWidth = 1; p.stroke() }
    if let a = accent {
      NSGraphicsContext.saveGraphicsState(); p.addClip()
      a.setFill(); NSRect(x: b.minX, y: b.minY, width: 4, height: b.height).fill()
      NSGraphicsContext.restoreGraphicsState()
    }
  }
}

// One session. A click anywhere but the autopilot switch opens it.
final class RowView: Card {
  let entry: Entry
  var onOpen: ((Entry) -> Void)?
  init(_ e: Entry, autopilot: Bool, onToggle: @escaping (Entry, Bool) -> Void) {
    entry = e
    super.init(frame: .zero)
    if e.done { fill = .clear; stroke = C.border.withAlphaComponent(0.5) } else { accent = C.orange }
    alphaValue = e.done ? 0.55 : 1
    let meta = (e.file.isEmpty ? [] : [timeLabel(e.ts), e.section, e.project].filter { !$0.isEmpty } + (e.done ? [T.handled] : []))
    let top = label(meta.joined(separator: "  ·  "), font(11, "Medium"), C.muted)
    let title = label(e.title.isEmpty ? "Claude Code" : e.title, font(14, "Bold"), C.ink)
    // Autopilot answers when a request arrives; the one already waiting was
    // shown before it was ticked, so it says so instead of looking answered.
    let pending = autopilot && !e.done && !e.file.isEmpty
    let msg = label(pending ? "\(e.msg)\n\(T.rowApPending)" : e.msg, font(13), C.ink, lines: 7)
    let toggle = Target { onToggle(e, !autopilot) }
    let sw = pill((autopilot ? "● " : "○ ") + T.rowAutopilot, filled: autopilot, size: 11, toggle)
    sw.isEnabled = !e.session.isEmpty && e.session != "none"
    let head = NSStackView(views: [title, NSView(), sw])
    head.orientation = .horizontal
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let col = NSStackView(views: [top, head, msg])
    col.orientation = .vertical
    col.alignment = .leading
    col.spacing = 3
    col.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 11, right: 12)
    col.translatesAutoresizingMaskIntoConstraints = false
    addSubview(col)
    NSLayoutConstraint.activate([
      col.leadingAnchor.constraint(equalTo: leadingAnchor), col.trailingAnchor.constraint(equalTo: trailingAnchor),
      col.topAnchor.constraint(equalTo: topAnchor), col.bottomAnchor.constraint(equalTo: bottomAnchor),
      head.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -28),
      msg.widthAnchor.constraint(equalTo: head.widthAnchor),
    ])
  }
  required init?(coder: NSCoder) { nil }
  override func mouseUp(with event: NSEvent) { onOpen?(entry) }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class Inbox: NSObject {
  let window: NSWindow
  let list = NSStackView()
  let heading = NSTextField(labelWithString: "")
  let status = NSTextField(labelWithString: "")
  let until = NSDatePicker()
  let bar = NSStackView()
  var footer: NSStackView!
  var signature = ""
  var targets: [Target] = []

  func untilText() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: until.dateValue)
  }

  override init() {
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.title = T.title
    window.appearance = NSAppearance(named: .aqua)   // Day, as every NoBrainer surface
    window.backgroundColor = C.canvas
    window.minSize = NSSize(width: 400, height: 260)
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("needs-you-window")

    let mark = NSImageView(image: logo("logo-64.png") ?? NSImage())
    mark.widthAnchor.constraint(equalToConstant: 30).isActive = true
    mark.heightAnchor.constraint(equalToConstant: 30).isActive = true
    heading.font = font(19, "ExtraBold")
    heading.textColor = C.ink
    let brand = NSStackView(views: [mark, heading])
    brand.spacing = 10

    // The end time of autopilot for all sessions. Changing it while autopilot
    // is on moves the end at once.
    until.datePickerStyle = .textFieldAndStepper
    until.datePickerElements = .hourMinute
    until.locale = Locale(identifier: "en_GB")   // 24-hour clock
    until.font = font(13, "SemiBold")
    until.dateValue = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    let untilT = Target { [unowned self] in
      if loadAutopilot().until != nil { runAutopilot(["on", self.untilText()]); self.refresh(force: true) }
    }
    targets.append(untilT)
    until.target = untilT
    until.action = #selector(Target.fire)
    status.font = font(12, "SemiBold")
    bar.orientation = .horizontal
    bar.spacing = 8

    list.orientation = .vertical
    list.alignment = .leading
    list.spacing = 8
    list.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 8, right: 0)
    let doc = FlippedView()
    doc.translatesAutoresizingMaskIntoConstraints = false
    list.translatesAutoresizingMaskIntoConstraints = false
    doc.addSubview(list)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = doc
    NSLayoutConstraint.activate([
      list.leadingAnchor.constraint(equalTo: doc.leadingAnchor), list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
      list.topAnchor.constraint(equalTo: doc.topAnchor), list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
      doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])

    let hint = label(T.hint, font(11), C.muted, lines: 2)
    hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let flow = NSButton(title: "", target: nil, action: nil)
    let flowT = Target { NSWorkspace.shared.open(URL(string: "https://github.com/nobrainer-tech/nobrainer-tech-flow")!) }
    flow.target = flowT; flow.action = #selector(Target.fire); flow.isBordered = false
    objc_setAssociatedObject(flow, "t", flowT, .OBJC_ASSOCIATION_RETAIN)
    let credit = NSMutableAttributedString(string: "nobrainer", attributes: [.font: font(12, "ExtraBold"), .foregroundColor: C.ink])
    credit.append(NSAttributedString(string: ".", attributes: [.font: font(12, "ExtraBold"), .foregroundColor: C.orange]))
    credit.append(NSAttributedString(string: "tech/flow ↗", attributes: [.font: font(12, "ExtraBold"), .foregroundColor: C.blue]))
    flow.attributedTitle = credit
    footer = NSStackView(views: [NSView(), flow])
    footer.orientation = .horizontal

    let root = NSStackView(views: [brand, bar, scroll, hint, footer])
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 12
    root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
    root.setCustomSpacing(4, after: hint)
    for v in [bar, scroll, hint, footer] as [NSView] { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    window.contentView = root
    refresh(force: true)
  }

  // Rebuild only when a file or the autopilot changed.
  func refresh(force: Bool = false) {
    let entries = loadEntries()
    let ap = loadAutopilot()
    let sig = entries.map { "\($0.file)|\($0.ts)|\($0.done)|\($0.msg)|\($0.title)" }.joined(separator: "\n")
      + "|\(ap.until ?? "")|\(ap.sessions.keys.sorted())"
    if !force && sig == signature { return }
    signature = sig

    let waiting = entries.filter { !$0.done }.count
    let head = NSMutableAttributedString(string: T.title, attributes: [.font: font(19, "ExtraBold"), .foregroundColor: C.ink])
    if waiting > 0 {
      head.append(NSAttributedString(string: "  \(waiting) \(T.waiting)", attributes: [.font: font(13, "Bold"), .foregroundColor: C.orange]))
    }
    heading.attributedStringValue = head
    window.title = waiting > 0 ? "\(T.title) (\(waiting))" : T.title
    NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil

    bar.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if let u = ap.until {
      let hhmm = String(u.suffix(5))
      status.stringValue = "● \(T.apOn) \(hhmm)"
      status.textColor = C.blue
      let parts = hhmm.split(separator: ":").compactMap { Int($0) }
      if parts.count == 2, window.firstResponder !== until,
         let d = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) {
        until.dateValue = d
      }
      bar.setViews([status, NSView(), until, pill(T.apStop, filled: false, Target { [unowned self] in
        runAutopilot(["off"]); self.refresh(force: true)
      })], in: .leading)
    } else {
      status.stringValue = "○ \(T.apOff)"
      status.textColor = C.muted
      bar.setViews([status, NSView(), pill(T.apStart, filled: true, Target { [unowned self] in
        runAutopilot(["on", self.untilText()]); self.refresh(force: true)
      }), until], in: .leading)
    }
    if entries.contains(where: { $0.done }) {
      bar.addArrangedSubview(pill(T.clear, filled: false, Target { [unowned self] in
        for e in loadEntries() where e.done { removeHandled(e) }
        self.refresh(force: true)
      }))
    }

    list.arrangedSubviews.forEach { $0.removeFromSuperview() }
    // A session on its own autopilot keeps a row, and so its switch, even when
    // it has no request in the inbox (cleared, expired, or all answered).
    let listed = Set(entries.map { $0.session })
    let onAutopilot = ap.sessions.filter { !listed.contains($0.key) }.sorted { $0.key < $1.key }.map { id, title in
      Entry(file: "", session: id, title: title, section: "", project: "", msg: T.rowOnAutopilot,
            link: id.hasPrefix("local_") ? "claude://claude.ai/epitaxy/\(id)" : "",
            ts: 0, doneTs: 0, done: true)
    }
    let rows = entries + onAutopilot
    if rows.isEmpty {
      list.addArrangedSubview(label(T.empty, font(14, "Medium"), C.muted))
      return
    }
    for e in rows {
      let row = RowView(e, autopilot: ap.sessions[e.session] != nil) { [unowned self] e, on in
        runAutopilot(["session", on ? "on" : "off", e.session, e.title])
        self.refresh(force: true)
      }
      row.onOpen = { [unowned self] e in
        if let u = URL(string: e.link), !e.link.isEmpty { NSWorkspace.shared.open(u) }
        markDone(e)
        self.refresh(force: true)
      }
      list.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  var inbox: Inbox!
  var timer: Timer?
  var scanTimer: Timer?
  func applicationDidFinishLaunching(_ n: Notification) {
    if let icon = logo("logo-512.png") { NSApp.applicationIconImage = icon }
    inbox = Inbox()
    if !inbox.window.setFrameUsingName("needs-you-window") { inbox.window.center() }
    // Shown on top, but the app you are typing in keeps the focus.
    inbox.window.orderFrontRegardless()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.inbox.refresh() }
    runScan()
    scanTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in runScan() }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
  func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
    inbox.window.makeKeyAndOrderFront(nil)
    return true
  }
}
