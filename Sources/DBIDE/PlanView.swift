import AppKit
import DBIDECore
import SwiftUI

/// Query plan as a tree: estimated vs actual rows, cost, and per-node self time.
struct PlanView: View {
    let plan: ExplainResult
    @State private var showRaw = false

    /// Pre-order list of all nodes with their depth (plans are shown fully expanded).
    private var flattened: [(node: PlanNode, depth: Int)] {
        var out: [(PlanNode, Int)] = []
        func walk(_ n: PlanNode, _ d: Int) {
            out.append((n, d))
            n.children.forEach { walk($0, d + 1) }
        }
        walk(plan.root, 0)
        return out
    }

    private var maxSelfTime: Double { plan.root.allNodes.compactMap(\.exclusiveTime).max() ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if let t = plan.planningTime { Text(String(format: "Planning %.2f ms", t)) }
                if let t = plan.executionTime { Text(String(format: "Execution %.2f ms", t)) }
                if !plan.analyzed { Text("Estimated plan — use Explain Analyze (⇧⌥⌘E) for actual timings").foregroundStyle(.secondary) }
                Spacer()
                Toggle("Raw", isOn: $showRaw).toggleStyle(.switch).controlSize(.mini)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plan.raw, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy raw plan")
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            if showRaw {
                ScrollView {
                    Text(plan.raw)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            } else {
                List(flattened, id: \.node.id) { item in
                    PlanRow(node: item.node, maxSelfTime: maxSelfTime, analyzed: plan.analyzed)
                        .padding(.leading, CGFloat(item.depth) * 18)
                        .overlay(alignment: .leading) {
                            if item.depth > 0 {
                                Text("└").foregroundStyle(.tertiary).font(.system(size: 12, design: .monospaced))
                                    .offset(x: CGFloat(item.depth) * 18 - 14)
                            }
                        }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 22)
            }
        }
    }
}

private struct PlanRow: View {
    let node: PlanNode
    let maxSelfTime: Double
    let analyzed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(.system(size: 12, weight: .medium, design: .monospaced))
                ForEach(node.details, id: \.self) { d in
                    Text(d).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            if let rows = node.planRows {
                rowsLabel(estimated: rows)
            }
            if let cost = node.totalCost {
                Text(String(format: "cost %.1f", cost)).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            }
            if analyzed {
                selfTime.frame(width: 150)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func rowsLabel(estimated: Double) -> some View {
        if let actual = node.actualRows {
            let total = actual * (node.loops ?? 1)
            let est = estimated * (node.loops ?? 1)
            let off = max(total, 1) / max(est, 1)
            let bad = off >= 10 || off <= 0.1
            Text("rows \(fmt(total)) / est \(fmt(est))")
                .foregroundStyle(bad ? .orange : .secondary)
                .help(bad ? "Row estimate is off by \(String(format: "%.0f", max(off, 1 / off)))× — consider ANALYZE / statistics" : "")
                .frame(width: 170, alignment: .trailing)
        } else {
            Text("rows \(fmt(estimated))").foregroundStyle(.secondary).frame(width: 170, alignment: .trailing)
        }
    }

    private var selfTime: some View {
        let t = node.exclusiveTime ?? 0
        let fraction = maxSelfTime > 0 ? t / maxSelfTime : 0
        return HStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fraction > 0.5 ? Color.red.opacity(0.7) : Color.accentColor.opacity(0.6))
                        .frame(width: g.size.width * fraction)
                }
            }
            .frame(height: 6)
            Text(String(format: "%.2f ms", t)).frame(width: 64, alignment: .trailing)
        }
        .help("Self time (excluding children); loops: \(fmt(node.loops ?? 1))")
    }

    private func fmt(_ v: Double) -> String {
        v >= 1e6 ? String(format: "%.1fM", v / 1e6) : v >= 1e4 ? String(format: "%.1fk", v / 1e3)
            : v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
