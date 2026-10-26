// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

enum AITerminalCaptureTest {
    static func run() -> [String: Bool] {
        var checks = [String: Bool]()
        let esc = "\u{1b}", prompt = "[fixture@fedora ~]$", command = "uptime"
        let body = "负载：0.10 0.20 0.30\n内存：32768 MiB 😀\n进程：fixture"
        let endings = ["\u{7}", esc + "\\"]
        for (startIndex, start) in endings.enumerated() {
            for (endIndex, end) in endings.enumerated() {
                let wire = Data((command + "\r\n" + esc + "]133;C" + start +
                    body + "\r\n" + esc + "]133;D;0" + end +
                    esc + "]7;file://fedora/fixture" + end + esc + "]0;fixture title" + end +
                    esc + "[32m" + prompt + esc + "[0m ").utf8)
                // Exercise every split position, including inside UTF-8 and ST.
                for split in 0...wire.count {
                    let capture = AITerminalCapture()
                    let first = capture.consume(Data(wire.prefix(split)))
                    let last = capture.consume(Data(wire.dropFirst(split)))
                    let key = "oscOutput-\(startIndex)-\(endIndex)-\(split)"
                    checks[key] = capture.result(command: command, prompt: prompt) == body && first + last == wire
                }
                let streamed = AITerminalCapture()
                for byte in wire { _ = streamed.consume(Data([byte])) }
                checks["oscByteStreaming-\(startIndex)-\(endIndex)"] = streamed.result(command: command, prompt: prompt) == body
            }
        }
        let strings = AITerminalCapture()
        let raw = command + "\r\n" + esc + "Psecret control data" + esc + "\\" +
            "VISIBLE" + esc + "_other control data" + esc + "\\\r\n" + prompt
        _ = strings.consume(Data(raw.utf8))
        checks["controlStringsDoNotLeakOrConsumeOutput"] = strings.result(command: command, prompt: prompt) == "VISIBLE"

        let partial = AITerminalCapture()
        _ = partial.consume(Data((command + "\r\nBODY\r\n" + prompt + esc + "]7;incomplete").utf8))
        checks["incompleteControlCannotComplete"] = partial.result(command: command, prompt: prompt) == nil
        _ = partial.consume(Data((esc + "\\").utf8))
        checks["splitControlTerminatorCompletes"] = partial.result(command: command, prompt: prompt) == "BODY"

        let cancelledControl = AITerminalCapture()
        _ = cancelledControl.consume(Data((command + "\r\n" + esc + "]0;cancelled\u{18}BODY\r\n" + prompt).utf8))
        checks["cancelledControlPreservesFollowingText"] = cancelledControl.result(command: command, prompt: prompt) == "BODY"

        let echo = AITerminalCapture()
        _ = echo.consume(Data((command + "\r\n" + command + "\r\n" + prompt).utf8))
        let echoed = echo.result(command: command, prompt: prompt) ?? ""
        checks["echoOnlyCannotBecomeEvidence"] = echo.collectionProblem(output: echoed, command: command, prompt: prompt, allowsEmptyOutput: false)?.contains(command) == true
        checks["emptyQueryIsExplicitlyUncertain"] = echo.collectionProblem(output: "", command: command, prompt: prompt, allowsEmptyOutput: false)?.contains("可能是空结果或采集异常") == true
        checks["silentMutationAllowedWithoutInventingExitStatus"] = echo.collectionProblem(output: "", command: "mkdir", prompt: prompt, allowsEmptyOutput: true) == nil
        checks["echoOnlyMutationStillRejected"] = echo.collectionProblem(output: echoed, command: command, prompt: prompt, allowsEmptyOutput: true) != nil

        let prefix = AITerminalCapture()
        _ = prefix.consume(Data(("uptime: unavailable\r\n" + prompt).utf8))
        checks["commandPrefixInOutputNotStripped"] = prefix.result(command: command, prompt: prompt) == "uptime: unavailable"
        let promptEcho = AITerminalCapture()
        _ = promptEcho.consume(Data((prompt + " " + command + "\r\nBODY\r\n" + prompt).utf8))
        checks["promptPrefixedEchoRemoved"] = promptEcho.result(command: command, prompt: prompt) == "BODY"
        let fakePrompt = AITerminalCapture()
        _ = fakePrompt.consume(Data((command + "\r\nBODY " + prompt).utf8))
        checks["promptMustOccupyItsOwnLine"] = fakePrompt.result(command: command, prompt: prompt) == nil
        return checks
    }
}
