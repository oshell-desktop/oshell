// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// An old prompt/OSC can arrive after authorization but before the bootstrap echo,
/// especially after Ctrl+C. Pass that output through and recognize only our exact
/// command, rather than assuming the next PTY byte starts its echo.
public struct AgentIntegrationEcho {
    private let command: String, first: UInt8
    private var candidate: HostProbeEcho?
    private var consumed = 0
    public private(set) var finished = false
    public init(command: String) { self.command = command; first = command.utf8.first ?? 0 }
    public mutating func consume(_ bytes: Data) -> Data {
        var result = Data()
        for byte in bytes {
            if finished { result.append(byte); continue }
            consumed += 1
            if consumed > 16_384 { result.append(flush()); result.append(byte); continue }
            if candidate == nil && byte != first { result.append(byte); continue }
            var echo = candidate ?? HostProbeEcho(command: command, shellEditing: true)
            let visible = echo.consume(Data([byte]))
            if echo.finished {
                candidate = nil
                if echo.matched { finished = true; result.append(visible) }
                else if byte == first, visible.last == byte {
                    // The mismatch itself may be the first character of our echo.
                    result.append(visible.dropLast())
                    var next = HostProbeEcho(command: command, shellEditing: true)
                    result.append(next.consume(Data([byte]))); candidate = next
                } else { result.append(visible) }
            } else { candidate = echo; result.append(visible) }
        }
        return result
    }
    public mutating func flush() -> Data {
        finished = true
        defer { candidate = nil }
        return candidate?.flush() ?? Data()
    }
}
