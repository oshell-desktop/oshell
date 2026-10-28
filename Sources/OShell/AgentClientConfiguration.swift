// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The UI and real-client fixtures use the same renderer. JSON's escaped slash is not valid TOML.
enum AgentClientConfiguration {
    static func codex(helper: String, socket: String, token: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        func quote(_ text: String) throws -> String { String(decoding: try encoder.encode(text), as: UTF8.self) }
        return try "[mcp_servers.oshell]\ncommand = \(quote(helper))\n[mcp_servers.oshell.env]\nOSHELL_AGENT_SOCKET = \(quote(socket))\nOSHELL_AGENT_TOKEN = \(quote(token))\n"
    }
    static func opencode(helper: String, socket: String, token: String) throws -> String {
        let value: [String: Any] = ["mcp": ["oshell": ["type": "local", "command": [helper], "environment": ["OSHELL_AGENT_SOCKET": socket, "OSHELL_AGENT_TOKEN": token], "enabled": true]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
