import SwiftUI

@MainActor
final class BackgroundProcessStore: ObservableObject {
    @Published private(set) var items: [BackgroundCleanupItem] = []
    @Published var selectedIDs = Set<String>()
    @Published private(set) var isWorking = false
    @Published private(set) var hasScanned = false
    @Published private(set) var status = "扫描运行中的模拟器与可能遗留的 Agent 任务"
    @Published private(set) var messages: [String] = []

    var selectedItems: [BackgroundCleanupItem] {
        items.filter { $0.canClean && selectedIDs.contains($0.id) }
    }

    func selectAll(_ selected: Bool) {
        guard !isWorking else { return }
        selectedIDs = selected ? Set(items.filter(\.canClean).map(\.id)) : []
    }

    func scan() {
        guard !isWorking else { return }
        isWorking = true
        selectedIDs = []
        status = "正在检查后台进程…"
        messages = []
        Task {
            do {
                let report = try await Task.detached(priority: .utility) {
                    try BackgroundProcessScanner().scan()
                }.value
                items = report.items
                messages = report.warnings
                hasScanned = true
                status = "发现 \(items.count) 项，\(items.filter(\.canClean).count) 项可供确认处理"
            } catch {
                items = []
                messages = [error.localizedDescription]
                status = "扫描失败，请重试"
            }
            isWorking = false
        }
    }

    func clean(_ pending: [BackgroundCleanupItem]) {
        guard !isWorking, !pending.isEmpty, pending.allSatisfy(\.canClean) else { return }
        isWorking = true
        selectedIDs = []
        status = "正在请求正常退出并核验结果…"
        messages = []
        Task {
            let result = await Task.detached(priority: .utility) {
                let cleaner = BackgroundProcessCleaner()
                var failures: [String] = []
                var completed = 0
                for item in pending {
                    do { try cleaner.clean(item); completed += 1 }
                    catch { failures.append("\(item.title)：\(error.localizedDescription)") }
                }
                return (completed, failures)
            }.value
            do {
                let report = try await Task.detached(priority: .utility) {
                    try BackgroundProcessScanner().scan()
                }.value
                items = report.items
                messages = result.1 + report.warnings
            } catch {
                items = []
                messages = result.1 + ["退出后重新扫描失败：\(error.localizedDescription)"]
            }
            status = "已关闭或结束 \(result.0) 项" + (result.1.isEmpty ? "" : "，\(result.1.count) 项需要检查")
            isWorking = false
        }
    }
}

struct BackgroundProcessesView: View {
    @ObservedObject var store: BackgroundProcessStore
    @State private var showingConfirmation = false
    @State private var pending: [BackgroundCleanupItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            introduction
            if !store.messages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(store.messages.enumerated()), id: \.offset) { _, message in
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if store.isWorking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(store.status).foregroundStyle(.secondary)
                }
            }
            if store.items.isEmpty && !store.isWorking {
                VStack(spacing: 12) {
                    Image(systemName: store.hasScanned ? "checkmark.circle" : "cpu")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(store.hasScanned ? "没有发现可列出的后台任务" : "检查后台残留")
                        .font(.headline)
                    Text("点击右上角扫描。只列出已识别的模拟器、旧版 Codex 崩溃报告、浏览器自动化和长时间未退出的 mas 任务。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
            } else if !store.items.isEmpty {
                selectionBar
                LazyVStack(spacing: 12) {
                    ForEach(store.items) { item in
                        BackgroundProcessRow(
                            item: item,
                            selected: Binding(
                                get: { store.selectedIDs.contains(item.id) },
                                set: { selected in
                                    if selected { store.selectedIDs.insert(item.id) }
                                    else { store.selectedIDs.remove(item.id) }
                                }
                            ),
                            isWorking: store.isWorking,
                            onClean: { confirm([$0]) }
                        )
                    }
                }
            }
        }
        .confirmationDialog(
            "关闭或结束这 \(pending.count) 项后台任务？",
            isPresented: $showingConfirmation, titleVisibility: .visible
        ) {
            Button("执行关闭与结束", role: .destructive) {
                let selected = pending
                pending = []
                store.clean(selected)
            }
            Button("取消", role: .cancel) { pending = [] }
        } message: {
            Text("请确认所选任务已经不再使用。模拟器正常关机并保留数据；进程收到正常退出请求，相关子进程也会结束。执行前会重新核验，状态变化的任务会跳过。")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("释放后台占用", systemImage: "cpu")
                .font(.title3.weight(.semibold))
            Text("运行时间长不代表任务已结束。请结合用途选择需要关闭的项目；扫描不会自动结束任何进程。")
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Label("\(store.items.filter { $0.category == "iOS Simulator" }.count) 台模拟器", systemImage: "iphone")
                Label("\(store.items.reduce(Int64(0)) { $0 + $1.residentBytes }.devSweepFileSize) RSS 合计", systemImage: "memorychip")
            }
            .font(.callout.monospacedDigit())
            Text("RSS 是驻留内存统计，包含共享页，不代表实际可释放量。构建和测试期间禁止关闭模拟器；当前应用、安装任务和无法确认身份的进程受保护。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var selectionBar: some View {
        HStack {
            Button("选择可处理项") { store.selectAll(true) }
            Button("取消选择") { store.selectAll(false) }
            Spacer()
            Text("已选 \(store.selectedItems.count) 项")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("处理所选…", role: .destructive) { confirm(store.selectedItems) }
                .disabled(store.selectedItems.isEmpty)
        }
        .buttonStyle(.bordered)
        .disabled(store.isWorking)
    }

    private func confirm(_ items: [BackgroundCleanupItem]) {
        pending = items
        showingConfirmation = true
    }
}

private struct BackgroundProcessRow: View {
    let item: BackgroundCleanupItem
    @Binding var selected: Bool
    let isWorking: Bool
    let onClean: (BackgroundCleanupItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Toggle("选择 \(item.title)", isOn: $selected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!item.canClean || isWorking)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.headline)
                    Text(item.reason).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(item.residentBytes.devSweepFileSize).font(.headline.monospacedDigit())
                    Text(item.canClean ? "确认后处理" : "受保护")
                        .font(.caption)
                        .foregroundStyle(item.canClean ? Color.orange : Color.secondary)
                }
                Button(item.actionTitle + "…", role: .destructive) { onClean(item) }
                    .buttonStyle(.bordered)
                    .disabled(!item.canClean || isWorking)
            }
            HStack(spacing: 16) {
                Text("PID \(item.root.pid)")
                Text("\(item.members.count) 个进程")
                Text("已运行 \(duration)")
                Text(item.category)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let protection = item.protection {
                Label(protection, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("查看进程与可执行文件") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.members, id: \.pid) { member in
                        Text("PID \(member.pid) · \(member.identity.executablePath.isEmpty ? "身份无法确认" : member.identity.executablePath)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var duration: String {
        let seconds = max(0, Int(Date().timeIntervalSince(item.root.identity.startedAt)))
        if seconds >= 86_400 { return "\(seconds / 86_400) 天 \((seconds % 86_400) / 3_600) 小时" }
        if seconds >= 3_600 { return "\(seconds / 3_600) 小时 \((seconds % 3_600) / 60) 分钟" }
        return "\(seconds / 60) 分钟"
    }
}
