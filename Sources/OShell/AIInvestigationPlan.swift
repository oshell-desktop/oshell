// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import OShellCore

/// Provider-independent tool plan. The model never supplies executable shell text.
struct AIInvestigationPlan: Decodable {
    enum Action: String, Decodable { case answer, query, complete, blocked }
    static let protocolVersion = "oshell.task.v1"
    let action: Action
    let summary: String
    let queries: [String]
    let evidence: [String]
    let reason: String
    enum CodingKeys: String, CodingKey { case `protocol`, action, summary, queries, evidence, reason }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .protocol) == Self.protocolVersion else { throw ModelError.invalid("任务协议版本不受支持。") }
        action = try c.decode(Action.self, forKey: .action)
        summary = try c.decode(String.self, forKey: .summary)
        queries = try c.decodeIfPresent([String].self, forKey: .queries) ?? []
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.utf8.count <= 8192, reason.utf8.count <= 4096,
              queries.count <= 2,
              (queries + evidence).allSatisfy({ $0.utf8.count <= 1024 }),
              action == .query ? !queries.isEmpty : queries.isEmpty else {
            throw ModelError.invalid("排查计划字段或数量无效。")
        }
    }
    static func parse(_ text: String) throws -> Self? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.utf8.count <= 65536 else { throw ModelError.invalid("任务回复超过协议长度限制。") }
        guard source.hasPrefix("{") else { return nil }
        do {
            let data = Data(source.utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["protocol", "action", "summary", "queries", "evidence", "reason"]) else { throw ModelError.invalid("未知任务协议字段。") }
            return try JSONDecoder().decode(Self.self, from: data)
        } catch { throw ModelError.invalid("任务回复不符合 oshell.task.v1；未执行任何操作。") }
    }
    static func isContinuationRequest(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "。！!.")).lowercased()
        return ["继续", "继续任务", "继续排查", "继续执行", "继续分析", "接着执行", "continue", "resume"].contains(value)
    }

}

struct AIInvestigationBudget {
    private(set) var counts = [AIReadOnlyQuery: Int]()
    private(set) var rounds = 0, bytes = 0
    private var outputs = [AIReadOnlyQuery: String]()
    private var unchanged = 0, failures = 0
    var queryCount: Int { counts.values.reduce(0, +) }
    func check(_ queries: [AIReadOnlyQuery]) throws {
        guard unchanged < 3 else { throw ModelError.invalid("连续复查没有获得新证据，已暂停。请补充线索或确认继续。") }
        guard failures < 3 else { throw ModelError.invalid("连续操作失败，已暂停；请检查失败原因再继续。") }
    }
    mutating func start(_ query: AIReadOnlyQuery) { counts[query, default: 0] += 1 }
    mutating func nextRound() throws { rounds += 1 }
    mutating func collect(_ text: String) throws { bytes += text.utf8.count }
    @discardableResult mutating func observe(_ query: AIReadOnlyQuery, output: String, exitCode: Int?) -> Bool {
        let changed = outputs[query] != output
        unchanged = changed ? 0 : unchanged + 1
        failures = exitCode.map { $0 == 0 ? 0 : failures + 1 } ?? 0
        outputs[query] = output
        return changed
    }
    mutating func resume() { unchanged = 0; failures = 0 }
}
