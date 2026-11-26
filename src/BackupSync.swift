// Backup & Sync — một màn hình: nguồn, đích, kiểu sync, bỏ qua, thời điểm, nút Thực hiện.
// Phần xử lý: Contents/Resources/fs-helper + folder-sync (Python, đã kiểm thử).
import AppKit
import SwiftUI

// MARK: - Helper bridge

enum Helper {
    static var path: String { Bundle.main.path(forResource: "fs-helper", ofType: nil) ?? "" }

    @discardableResult
    static func run(_ args: [String], onStart: ((pid_t) -> Void)? = nil) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (1, "Không chạy được: \(error.localizedDescription)") }
        onStart?(p.processIdentifier)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
    @Published var source = ""
    @Published var dest = ""
    @Published var direction: Direction = .a2b
    @Published var exclude = ""
    @Published var when: When = .now
    @Published var time = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    @Published var schedules: [Schedule] = []
    @Published var output = ""
    @Published var busy = false
    @Published var confirmText: String?
    @Published var screen: Screen = .form
    @Published var cancelling = false
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Chọn"
        panel.message = isSource ? "Chọn thư mục Nguồn" : "Chọn thư mục Đích"
        let current = isSource ? source : dest
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current) }
        if panel.runModal() == .OK, let url = panel.url {
            if isSource { source = url.path } else { dest = url.path }
        }
    }

    func swap() { (source, dest) = (dest, source) }

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
            .filter { !$0.hasPrefix("[20") && !$0.hasPrefix("Đang đọc") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func preview(thenConfirm: Bool = false) {
        guard validate() else { return }
        saveSettings()
        output = "Đang xem trước…"
        background({ Helper.run(["run", "--dry-run"]) }) { code, out in
            let text = Model.clean(out)
            self.output = text
            guard thenConfirm else { return }
            guard code == 0 else {
                // Never fail silently: say why nothing was copied.
                self.output = "⚠️ Chưa chép gì vì bước xem trước gặp lỗi (mã \(code)).\n\n" + text
                return
            }
            if text.contains("Không có gì để làm") { return }
            self.confirmText = Model.summary(text)
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
        let started = Date(), direction = direction, source = source
        background({
            Helper.run(["run"]) { pid in DispatchQueue.main.async { self.runningPID = pid } }
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
            case .running: RunningView(direction: m.direction, cancelling: m.cancelling) { m.cancel() }
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
                .disabled(m.busy)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .alert("Thực hiện đồng bộ?", isPresented: Binding(get: { m.confirmText != nil }, set: { if !$0 { m.confirmText = nil } })) {
            Button("Huỷ", role: .cancel) {}
            Button("Thực hiện") { m.runForReal() }
        } message: {
            Text(m.confirmText ?? "")
        }
    }
}

// MARK: - Running and result screens

struct RunningView: View {
    let direction: Direction
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
            ProgressView().controlSize(.large)
            Text(cancelling ? "Đang huỷ…" : title).font(.title2.weight(.semibold))
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
    var body: some Scene {
        WindowGroup("Backup & Sync") { ContentView() }
            .windowResizability(.contentSize)
    }
}
