// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum AgentOutputEncoding {
    /// Prefer lossless UTF-8 through the full read limit. Reserve room for response metadata;
    /// control-heavy UTF-8 expands in JSON, then again in MCP's text content envelope.
    public static func compact(_ output: Data) -> [String: AgentValue] {
        if let text = String(data: output, encoding: .utf8),
           let encoded = try? JSONEncoder().encode(text),
           let envelope = try? JSONEncoder().encode(String(decoding: encoded, as: UTF8.self)),
           envelope.count <= AgentIPC.maxFrame - 8192 {
            return ["encoding": .string("utf8"), "output_text": .string(text)]
        }
        return ["encoding": .string("base64"), "output_base64": .string(output.base64EncodedString())]
    }
}
