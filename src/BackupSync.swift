// Backup & Sync — một màn hình: nguồn, đích, kiểu sync, bỏ qua, thời điểm, nút Thực hiện.
// Phần xử lý: Contents/Resources/fs-helper + folder-sync (Python, đã kiểm thử).
import AppKit
import SwiftUI

// MARK: - Helper bridge

enum Helper {
    static var path: String { Bundle.main.path(forResource: "fs-helper", ofType: nil) ?? "" }

    @discardableResult
    /// Runs the helper and waits. `onLine` receives each output line as it arrives (used for "@@" progress lines).
    static func run(_ args: [String], onStart: ((pid_t) -> Void)? = nil,
                    onLine: ((String) -> Void)? = nil) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (1, "Không chạy được: \(error.localizedDescription)") }
        onStart?(p.processIdentifier)
        var data = Data(), pending = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            guard let onLine else { continue }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 10) {
                onLine(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

struct Schedule: Identifiable, Hashable {
    let id: String     // launchd label
    let text: String
}

enum Direction: String, CaseIterable, Identifiable {
    case a2b, b2a, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .a2b: return "Một chiều đi  →"
        case .b2a: return "Một chiều ngược  ←"
        case .both: return "Hai chiều  ⇄"
        }
    }
    var help: String {
        switch self {
        case .a2b: return "Sao lưu: tạo bản mới Đích/<tên nguồn>/<ngày_giờ>/ và cập nhật latest. Giữ 20 bản gần nhất; file không đổi dùng chung nên không tốn thêm chỗ."
        case .b2a: return "Khôi phục: chép từ bản latest về Nguồn những file bị thiếu hoặc cũ hơn. Không ghi đè file mới hơn, không xoá gì ở Nguồn."
        case .both: return "Khôi phục từ latest những file thiếu hoặc cũ hơn ở Nguồn, rồi tạo một bản sao lưu mới."
        }
    }
}

enum When: String, CaseIterable, Identifiable {
    case now, daily, hourly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .now: return "Chạy ngay"
        case .daily: return "Mỗi ngày"
        case .hourly: return "Mỗi giờ"
        }
    }
}

/// Outcome of a real run, shown on its own screen so the user clearly sees the job has finished.
struct RunResult {
    enum Status { case ok, warning, failed, cancelled }
    let status: Status
    let direction: Direction
    let highlights: [String]   // the few lines that matter (counts, check, errors)
    let details: String        // full helper output
    let folder: String?        // folder to open in Finder (new backup, or Nguồn after a restore)
    let finished: Date
    let seconds: Int

    var title: String {
        switch status {
        case .cancelled: return "Đã huỷ"
        case .failed: return "Có lỗi, chưa xong"
        case .warning: return "Đã xong, nhưng cần kiểm tra"
        case .ok:
            switch direction {
            case .a2b: return "Sao lưu xong"
            case .b2a: return "Khôi phục xong"
            case .both: return "Khôi phục và sao lưu xong"
            }
        }
    }

    static func from(code: Int32, output: String, direction: Direction, source: String, started: Date,
                     cancelled: Bool) -> RunResult {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let failed = code != 0 || lines.contains { $0.hasPrefix("CÓ LỖI") || $0.hasPrefix("Lỗi") }
        let warning = lines.contains { $0.contains("KHÁC") || $0.contains("THIẾU") }
        if cancelled {
            var notes = lines.filter { $0.hasPrefix("Đã xoá bản sao lưu dang dở") || $0.hasPrefix("đã chép về Nguồn") }
            if direction != .a2b {
                notes.append("Những file đã kịp khôi phục về Nguồn vẫn được giữ.")
            }
            return RunResult(status: .cancelled, direction: direction, highlights: notes, details: output,
                             folder: nil, finished: Date(), seconds: Int(Date().timeIntervalSince(started)))
        }
        let keys = ["Xong sau", "Kiểm tra", "đã chép về Nguồn", "Không có file nào cần khôi phục", "CÓ LỖI", "Lỗi", "rsync"]
        let highlights = lines.filter { l in keys.contains { l.hasPrefix($0) } }
        // The new backup folder is printed as "Đích  : <path>"; after a pure restore, open Nguồn instead.
        let backup = lines.first { $0.hasPrefix("Đích") && $0.contains(":") }
            .map { String($0[$0.index(after: $0.firstIndex(of: ":")!)...]).trimmingCharacters(in: .whitespaces) }
        let folder = direction == .b2a ? source : backup
        return RunResult(status: failed ? .failed : (warning ? .warning : .ok), direction: direction,
                         highlights: Array(highlights.prefix(12)), details: output,
                         folder: folder.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil },
                         finished: Date(), seconds: Int(Date().timeIntervalSince(started)))
    }
}

enum Screen {
    case form
    case running
    case done(RunResult)
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    // Changing any of these invalidates the last preview, so "nothing new" no longer applies.
    @Published var source = "" { didSet { if source != oldValue { nothingNew = nil } } }
    @Published var dest = "" { didSet { if dest != oldValue { nothingNew = nil } } }
    @Published var direction: Direction = .a2b { didSet { if direction != oldValue { nothingNew = nil } } }
    @Published var exclude = "" { didSet { if exclude != oldValue { nothingNew = nil } } }
    /// Set when the last preview found nothing to copy: Run is disabled and this sentence says why.
    @Published var nothingNew: String?
    @Published var when: When = .now
    @Published var time = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    @Published var schedules: [Schedule] = []
    @Published var output = ""
    @Published var busy = false
    @Published var confirmText: String?
    @Published var screen: Screen = .form
    @Published var cancelling = false
    @Published var progress = RunProgress()
    private var runningPID: pid_t?

    init() { load() }

    func load() {
        for line in Helper.run(["get"]).out.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "source": source = parts[1]
            case "dest": dest = parts[1]
            case "direction": direction = Direction(rawValue: parts[1]) ?? .a2b
            case "exclude": exclude = parts[1]
            default: break
            }
        }
        loadSchedules()
    }

    func loadSchedules() {
        schedules = Helper.run(["schedule-list"]).out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return p.count == 2 ? Schedule(id: p[0], text: p[1]) : nil
        }
    }

    private func saveSettings() {
        Helper.run(["set", "source", source])
        Helper.run(["set", "dest", dest])
        Helper.run(["set", "direction", direction.rawValue])
        Helper.run(["set", "exclude", exclude])
    }

    func pick(_ isSource: Bool) {
        if let path = chooseFolder(isSource ? "Chọn thư mục Nguồn" : "Chọn thư mục Đích", current: isSource ? source : dest) {
            if isSource { source = path } else { dest = path }
        }
    }

    func swap() { (source, dest) = (dest, source) }

    func apply(_ p: Preset) {
        source = p.source
        dest = p.dest
        exclude = p.exclude
    }

    private func background(_ work: @escaping () -> (Int32, String), done: @escaping (Int32, String) -> Void) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out) = work()
            DispatchQueue.main.async {
                self.busy = false
                done(code, out)
            }
        }
    }

    private static func clean(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("[20") && !$0.hasPrefix("Đang đọc") && !$0.hasPrefix("@@") && !$0.hasPrefix("Terminated") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func preview(thenConfirm: Bool = false) {
        guard validate() else { return }
        saveSettings()
        output = "Đang xem trước…"
        background({ Helper.run(["run", "--dry-run"]) }) { code, out in
            let text = Model.clean(out)
            self.output = text
            self.nothingNew = code == 0 ? self.nothingNewReason(text) : nil
            guard thenConfirm else { return }
            guard code == 0 else {
                // Never fail silently: say why nothing was copied.
                self.output = "⚠️ Chưa chép gì vì bước xem trước gặp lỗi (mã \(code)).\n\n" + text
                return
            }
            if self.nothingNew != nil { return }
            self.confirmText = Model.summary(text)
        }
    }

    /// A backup that changes nothing would only add a duplicate snapshot (and push an older one out of the 20 kept).
    private func nothingNewReason(_ text: String) -> String? {
        let backupNone = text.contains("Chạy thử xong: 0 mục mới hoặc đã thay đổi")
        let restoreNone = text.contains("Không có file nào cần khôi phục")
        switch direction {
        case .a2b:
            return backupNone ? "Không có gì thay đổi kể từ bản sao lưu gần nhất, nên chưa cần sao lưu lại." : nil
        case .b2a:
            return restoreNone ? "Nguồn đã có đủ file của bản sao lưu gần nhất, nên không có gì để khôi phục." : nil
        case .both:
            return backupNone && restoreNone ? "Nguồn và bản sao lưu gần nhất đã giống nhau, nên không có gì để làm." : nil
        }
    }

    func perform() {
        guard validate() else { return }
        saveSettings()
        switch when {
        case .now:
            preview(thenConfirm: true)
        case .daily:
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            let hhmm = String(format: "%02d:%02d", c.hour ?? 18, c.minute ?? 0)
            output = Helper.run(["schedule-add", "daily", hhmm]).out
            loadSchedules()
        case .hourly:
            output = Helper.run(["schedule-add", "hourly", "0"]).out
            loadSchedules()
        }
    }

    func runForReal() {
        output = "Đang chạy…"
        screen = .running
        cancelling = false
        progress = RunProgress()
        let started = Date(), direction = direction, source = source
        background({
            Helper.run(["run", "--progress"],
                       onStart: { pid in DispatchQueue.main.async { self.runningPID = pid } },
                       onLine: { line in
                           guard line.hasPrefix("@@") else { return }
                           DispatchQueue.main.async { self.progress.apply(line) }
                       })
        }) { code, out in
            self.runningPID = nil
            let text = Model.clean(out)
            self.output = text
            self.screen = .done(RunResult.from(code: code, output: text, direction: direction, source: source,
                                               started: started, cancelled: self.cancelling))
        }
    }

    /// fs-helper runs in its own process group, so signalling the group also stops bash and rsync.
    /// The engine then removes the unfinished snapshot and reports; the result screen shows "Đã huỷ".
    func cancel() {
        guard let pid = runningPID, !cancelling else { return }
        cancelling = true
        if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
    }

    func remove(_ s: Schedule) {
        Helper.run(["schedule-remove", s.id])
        loadSchedules()
    }

    private func validate() -> Bool {
        if source.isEmpty || dest.isEmpty {
            output = "Hãy chọn cả thư mục Nguồn và Đích."
            return false
        }
        return true
    }

    private static func summary(_ text: String) -> String {
        let keep = text.split(separator: "\n").filter {
            $0.contains("chép") || $0.contains("Khôi phục") || $0.contains("Đích  :") || $0.contains("xoá ở") || $0.contains("xung đột")
        }
        return keep.isEmpty ? "Thực hiện đồng bộ?" : keep.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }
}

// MARK: - Views

struct FolderRow: View {
    let label: String
    let symbol: String
    @Binding var path: String
    let choose: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField("", text: $path, prompt: Text("Chưa chọn"))
                    .textFieldStyle(.roundedBorder)
                    .truncationMode(.middle)
                Button("Chọn…", action: choose)
            }
        } label: {
            Label(label, systemImage: symbol)
        }
    }
}

struct ContentView: View {
    @StateObject private var m = Model()
    @EnvironmentObject private var presets: PresetStore
    @State private var showSave = false
    @State private var saveName = ""

    /// "v2.1 · build 20261126.1812" — the build number is the build time, stamped by scripts/build.sh.
    static let buildLabel: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "v\(version) · build \(build)"
    }()

    var body: some View {
        Group {
            switch m.screen {
            case .form: mainScreen
            case .running: RunningView(direction: m.direction, progress: m.progress, cancelling: m.cancelling) { m.cancel() }
            case .done(let r): ResultView(result: r) { m.screen = .form }
            }
        }
        // Fixed width (no wide side margins); only the height can be changed.
        .frame(width: Self.windowWidth)
        .frame(minHeight: 600, idealHeight: 720, maxHeight: .infinity)
        .background(WindowConfigurator())
    }

    static let windowWidth: CGFloat = 640

    private var mainScreen: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent {
                        Menu {
                            ForEach(presets.items) { p in
                                Button(p.name) { m.apply(p) }
                            }
                            if !presets.items.isEmpty { Divider() }
                            Button("Lưu Nguồn và Đích hiện tại…") {
                                saveName = presets.matching(source: m.source, dest: m.dest)?.name
                                    ?? Preset.suggestedName(source: m.source, dest: m.dest)
                                showSave = true
                            }
                            .disabled(m.source.isEmpty || m.dest.isEmpty)
                            OpenSettingsButton(title: "Quản lý cấu hình…")
                        } label: {
                            Text(presets.matching(source: m.source, dest: m.dest)?.name
                                 ?? (presets.items.isEmpty ? "Chưa lưu cấu hình nào" : "Chọn cấu hình đã lưu"))
                        }
                        .fixedSize()
                    } label: {
                        Label("Cấu hình", systemImage: "bookmark")
                    }
                    FolderRow(label: "Nguồn", symbol: "folder", path: $m.source) { m.pick(true) }
                    FolderRow(label: "Đích", symbol: "externaldrive", path: $m.dest) { m.pick(false) }
                    Text("Bản sao lưu nằm ở Đích/\((m.source as NSString).lastPathComponent)/<ngày_giờ>/ (kèm đường tắt latest).")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button { m.swap() } label: { Label("Đổi chỗ Nguồn và Đích", systemImage: "arrow.up.arrow.down") }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                .disabled(m.busy)

                Section {
                    Picker("Kiểu sync", selection: $m.direction) {
                        ForEach(Direction.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(m.direction.help).font(.callout).foregroundStyle(.secondary)
                    LabeledContent("Bỏ qua") {
                        TextField("", text: $m.exclude, prompt: Text("ví dụ: node_modules, .DS_Store"))
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Tên thư mục/file, cách nhau bằng dấu phẩy. Để trống = sao lưu tất cả (kể cả file ẩn).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .disabled(m.busy)

                Section {
                    Picker("Thời điểm", selection: $m.when) {
                        ForEach(When.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if m.when == .daily {
                        DatePicker("Chạy lúc", selection: $m.time, displayedComponents: .hourAndMinute)
                    }
                    if m.when != .now {
                        Text("Máy cần đang bật và ổ đích đang cắm. Xong mỗi lần sẽ có thông báo.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !m.schedules.isEmpty {
                        ForEach(m.schedules) { s in
                            HStack {
                                Image(systemName: "clock").foregroundStyle(.secondary)
                                Text(s.text).font(.callout).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(role: .destructive) { m.remove(s) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Xoá lịch này")
                            }
                        }
                    }
                } header: {
                    Text(m.schedules.isEmpty ? "Lịch" : "Lịch (\(m.schedules.count) đã hẹn)")
                }
                .disabled(m.busy)

                Section("Kết quả") {
                    ScrollView {
                        Text(m.output.isEmpty ? "Bấm Xem trước để xem sẽ chép hoặc xoá gì." : m.output)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(m.output.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 110, maxHeight: 220)
                }
            }
            .formStyle(.grouped)

            Divider()
            if m.when == .now, let why = m.nothingNew {
                Label {
                    Text(why + " Bấm Xem trước để kiểm tra lại khi có thay đổi.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            HStack(spacing: 12) {
                Text(Self.buildLabel)
                    .font(.caption).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                if m.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Xem trước") { m.preview() }
                    .disabled(m.busy)
                Button { m.perform() } label: {
                    Text(m.when == .now ? "Thực hiện" : "Thực hiện (hẹn giờ)").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(m.busy || (m.when == .now && m.nothingNew != nil))
                .help(m.when == .now ? (m.nothingNew ?? "") : "")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .alert("Lưu cấu hình", isPresented: $showSave) {
            TextField("Tên", text: $saveName)
            Button("Huỷ", role: .cancel) {}
            Button("Lưu") {
                let name = saveName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                presets.save(Preset(name: name, source: m.source, dest: m.dest, exclude: m.exclude), old: name)
            }
        } message: {
            Text("Lưu Nguồn, Đích và Bỏ qua hiện tại để lần sau chọn nhanh. Trùng tên sẽ cập nhật cấu hình cũ.")
        }
        .alert("Thực hiện đồng bộ?", isPresented: Binding(get: { m.confirmText != nil }, set: { if !$0 { m.confirmText = nil } })) {
            Button("Huỷ", role: .cancel) {}
            Button("Thực hiện") { m.runForReal() }
        } message: {
            Text(m.confirmText ?? "")
        }
    }
}

// MARK: - Presets (saved Nguồn/Đích pairs), managed in Settings

@MainActor
func chooseFolder(_ message: String, current: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Chọn"
    panel.message = message
    if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current) }
    return panel.runModal() == .OK ? panel.url?.path : nil
}

struct Preset: Codable, Identifiable, Hashable {
    var name: String
    var source: String
    var dest: String
    var exclude: String
    var id: String { name }

    /// "mathgpt-figma-design-system → Backups"
    static func suggestedName(source: String, dest: String) -> String {
        let s = (source as NSString).lastPathComponent, d = (dest as NSString).lastPathComponent
        return s.isEmpty ? d : (d.isEmpty ? s : "\(s) → \(d)")
    }
}

/// Saved presets live in the helper's settings file (~/.config/folder-sync/app.json, key "presets").
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var items: [Preset] = []

    init() { reload() }

    func reload() {
        let out = Helper.run(["preset-list"]).out
        items = (try? JSONDecoder().decode([Preset].self, from: Data(out.utf8))) ?? []
    }

    /// Adds or updates a preset (renaming when `old` differs). Returns an error message, or nil on success.
    @discardableResult
    func save(_ p: Preset, old: String? = nil) -> String? {
        var obj = ["name": p.name, "source": p.source, "dest": p.dest, "exclude": p.exclude]
        if let old { obj["old"] = old }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return "Không lưu được." }
        let r = Helper.run(["preset-save", json])
        reload()
        return r.code == 0 ? nil : r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func delete(_ p: Preset) {
        Helper.run(["preset-delete", p.name])
        reload()
    }

    func matching(source: String, dest: String) -> Preset? {
        items.first { $0.source == source && $0.dest == dest }
    }
}

/// Opens the Settings window (⌘,) from a button or menu.
struct OpenSettingsButton: View {
    let title: String
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text(title) }
        } else {
            Button(title) { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: PresetStore
    @State private var editing: Preset?
    @State private var editingOld: String?
    @State private var toDelete: Preset?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cấu hình đã lưu").font(.title3.weight(.semibold))
            Text("Mỗi cấu hình gồm Nguồn, Đích và danh sách Bỏ qua. Ở màn chính, chọn ở mục **Cấu hình** để điền nhanh.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bookmark").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Chưa có cấu hình nào").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                List {
                    ForEach(store.items) { p in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(.body.weight(.medium))
                                Text("\(p.source)  →  \(p.dest)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Sửa") { editingOld = p.name; editing = p }
                            Button(role: .destructive) { toDelete = p } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Xoá cấu hình này")
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }

            HStack {
                Button {
                    editingOld = nil
                    editing = Preset(name: "", source: "", dest: "", exclude: "node_modules")
                } label: { Label("Thêm cấu hình…", systemImage: "plus") }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
        .sheet(item: $editing) { p in
            PresetEditor(draft: p, old: editingOld).environmentObject(store)
        }
        .confirmationDialog("Xoá cấu hình \"\(toDelete?.name ?? "")\"?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Xoá", role: .destructive) { if let p = toDelete { store.delete(p) } }
        } message: {
            Text("Chỉ xoá lối tắt này. Thư mục và các bản sao lưu không bị ảnh hưởng.")
        }
    }
}

struct PresetEditor: View {
    @EnvironmentObject var store: PresetStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: Preset
    let old: String?
    @State private var error: String?

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespaces) }
    private var nameTaken: Bool { store.items.contains { $0.name == trimmedName && $0.name != old } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(old == nil ? "Thêm cấu hình" : "Sửa cấu hình")
                .font(.title3.weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                TextField("Tên", text: $draft.name, prompt: Text("ví dụ: Dự án → Ổ 4TB"))
                FolderRow(label: "Nguồn", symbol: "folder", path: $draft.source) {
                    if let p = chooseFolder("Chọn thư mục Nguồn", current: draft.source) {
                        draft.source = p
                        if trimmedName.isEmpty { draft.name = Preset.suggestedName(source: p, dest: draft.dest) }
                    }
                }
                FolderRow(label: "Đích", symbol: "externaldrive", path: $draft.dest) {
                    if let p = chooseFolder("Chọn thư mục Đích", current: draft.dest) { draft.dest = p }
                }
                TextField("Bỏ qua", text: $draft.exclude, prompt: Text("ví dụ: node_modules, .DS_Store"))
            }
            .formStyle(.grouped)
            if let msg = error ?? (nameTaken ? "Đã có cấu hình tên \"\(trimmedName)\"." : nil) {
                Text(msg).font(.callout).foregroundStyle(.red).padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Huỷ", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu") {
                    var p = draft
                    p.name = trimmedName
                    if let e = store.save(p, old: old) { error = e } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || draft.source.isEmpty || draft.dest.isEmpty || nameTaken)
            }
            .padding(20)
        }
        .frame(width: 520)
    }
}

// MARK: - Running and result screens

/// Progress reported by the engine as "@@PHASE x", "@@TOTAL n", "@@DONE n" lines.
struct RunProgress {
    var phase = ""          // restore | count | copy | verify
    var total: Int?
    var done = 0

    mutating func apply(_ line: String) {
        let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
        guard let key = parts.first else { return }
        let value = parts.count > 1 ? parts[1] : ""
        switch key {
        case "PHASE": phase = value
        case "TOTAL": total = Int(value)
        case "DONE": done = Int(value) ?? done
        default: break
        }
    }

    /// 0…1 while copying with a known total; nil means "working, amount unknown" (indeterminate bar).
    var fraction: Double? {
        guard phase == "copy", let total, total > 0 else { return phase == "verify" ? 1 : nil }
        return min(Double(done) / Double(total), 1)
    }

    var status: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "vi_VN")
        func n(_ x: Int) -> String { f.string(from: NSNumber(value: x)) ?? "\(x)" }
        switch phase {
        case "restore": return "Đang khôi phục file về Nguồn…"
        case "count": return "Đang tìm các mục cần sao lưu…"
        case "copy":
            guard let total else { return "Đang chép…" }
            return "Đã xử lý \(n(min(done, total))) / \(n(total)) mục"
        case "verify": return "Đang kiểm tra bản sao…"
        default: return "Đang chuẩn bị…"
        }
    }
}

struct RunningView: View {
    let direction: Direction
    let progress: RunProgress
    let cancelling: Bool
    let onCancel: () -> Void
    @State private var started = Date()

    private var title: String {
        switch direction {
        case .a2b: return "Đang sao lưu…"
        case .b2a: return "Đang khôi phục…"
        case .both: return "Đang khôi phục và sao lưu…"
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: direction == .b2a ? "arrow.down.doc.fill" : "externaldrive.fill.badge.timemachine")
                .font(.system(size: 56)).foregroundStyle(.green)
            Text(cancelling ? "Đang huỷ…" : title).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                if let f = progress.fraction {
                    ProgressView(value: f).progressViewStyle(.linear).tint(.green)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(.green)
                }
                HStack {
                    Text(progress.status).monospacedDigit()
                    Spacer()
                    if let f = progress.fraction, progress.phase == "copy" {
                        Text("\(Int(f * 100))%").monospacedDigit()
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text("Đã chạy \(Self.duration(Int(ctx.date.timeIntervalSince(started))))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Text("Đừng tháo ổ đĩa hay tắt máy cho tới khi xong.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(role: .cancel, action: onCancel) {
                Text(cancelling ? "Đang huỷ…" : "Huỷ").frame(minWidth: 120)
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .disabled(cancelling)
            .help("Dừng lại. Bản sao lưu đang làm dở sẽ bị xoá; các bản trước vẫn nguyên vẹn.")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func duration(_ s: Int) -> String {
        s < 60 ? "\(s) giây" : "\(s / 60) phút \(s % 60) giây"
    }
}

struct ResultView: View {
    let result: RunResult
    let onBack: () -> Void
    @State private var showDetails = false

    private var icon: (name: String, color: Color) {
        switch result.status {
        case .ok: return ("checkmark.circle.fill", .green)
        case .warning: return ("exclamationmark.triangle.fill", .orange)
        case .failed: return ("xmark.octagon.fill", .red)
        case .cancelled: return ("stop.circle.fill", .secondary)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: icon.name)
                        .font(.system(size: 64)).foregroundStyle(icon.color)
                        .padding(.top, 40)
                    Text(result.title).font(.title.weight(.semibold))
                    Text("Lúc \(result.finished.formatted(date: .omitted, time: .shortened)) · mất \(RunningView.duration(result.seconds))")
                        .foregroundStyle(.secondary)
                    if !result.highlights.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(result.highlights, id: \.self) { Text($0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    DisclosureGroup("Chi tiết", isExpanded: $showDetails) {
                        Text(result.details)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
            Divider()
            HStack(spacing: 12) {
                if let folder = result.folder {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                    } label: {
                        Label(result.direction == .b2a ? "Mở thư mục Nguồn" : "Mở bản sao lưu", systemImage: "folder")
                    }
                }
                Spacer()
                Button(action: onBack) {
                    Label("Quay lại", systemImage: "chevron.backward").frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

/// Turns off full screen for the window (the green button then only zooms the height).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.collectionBehavior.remove(.fullScreenPrimary)
            w.collectionBehavior.insert(.fullScreenNone)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@main
struct BackupSyncApp: App {
    @StateObject private var presets = PresetStore()

    var body: some Scene {
        WindowGroup("Backup & Sync") { ContentView().environmentObject(presets) }
            .windowResizability(.contentSize)
        Settings { SettingsView().environmentObject(presets) }
    }
}
