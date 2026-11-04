// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Built with OShellCore sources. Credentials arrive over stdin from the local probe.
struct LiveResult: Encodable {
    let initialFontSizeReadByB: Double
    let concurrentWriters: [String]
    let winningClient: String
    let winningFontSize: Double
    let staleWriteRejected: Bool
    let clockReadByA: Bool
    let fontSizeReadByA: Double
}

func verify() throws -> LiveResult {
    let settings = try JSONDecoder().decode(WebDAVSettings.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let a = try WebDAVClient(settings), b = try WebDAVClient(settings)
    let master = "nutstore-live-synthetic-fixture"
    var config = Configuration(profiles: [])
    config.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
    config.preferences.fontSize = 14
    let initial = try SharedVault.encode(config, password: master)
    try a.put(initial, replacing: nil)
    do { try b.put(initial, replacing: nil); throw ModelError.invalid("重复创建成功") }
    catch WebDAVFailure.conflict {}
    guard let original = try a.fetch(), try b.fetch() == original else { throw ModelError.invalid("初次读取不一致") }

    let firstRead = try SharedVault.decode(original.data, password: master)
    guard firstRead.preferences.fontSize == 14, !firstRead.preferences.terminalClockEnabled else {
        throw ModelError.invalid("首次同步的客户端设置不符")
    }
    let edits = try [18, 22].map { size -> Data in
        var edit = config
        edit.preferences.fontSize = Double(size)
        return try SharedVault.encode(edit, password: master)
    }
    let clients = [a, b], lock = NSLock()
    var outcomes = ["failed", "failed"]
    DispatchQueue.concurrentPerform(iterations: 2) { i in
        do {
            try clients[i].put(edits[i], replacing: original)
            lock.lock(); outcomes[i] = "committed"; lock.unlock()
        } catch WebDAVFailure.occupied {
            lock.lock(); outcomes[i] = "occupied"; lock.unlock()
        } catch WebDAVFailure.conflict {
            lock.lock(); outcomes[i] = "conflict"; lock.unlock()
        } catch {}
    }
    guard let winner = outcomes.firstIndex(of: "committed"), ["occupied", "conflict"].contains(outcomes[1 - winner]),
          let current = try b.fetch(), current.data == edits[winner] else {
        throw ModelError.invalid("并发写入未得到唯一胜者")
    }
    do { try a.put(initial, replacing: original); throw ModelError.invalid("过期写入成功") }
    catch WebDAVFailure.conflict {}
    guard try b.fetch()?.data == current.data else { throw ModelError.invalid("过期写入改变了远端设置") }
    var merged = try SharedVault.decode(current.data, password: master)
    merged.preferences.terminalClockEnabled = true
    try b.put(SharedVault.encode(merged, password: master), replacing: current)
    guard let latest = try a.fetch() else { throw ModelError.invalid("第二台设备更新后文件缺失") }
    let checked = try SharedVault.decode(latest.data, password: master)
    guard checked.preferences.fontSize == merged.preferences.fontSize, checked.preferences.terminalClockEnabled else {
        throw ModelError.invalid("客户端设置未双向保留")
    }
    return LiveResult(initialFontSizeReadByB: firstRead.preferences.fontSize, concurrentWriters: outcomes,
                      winningClient: winner == 0 ? "A" : "B", winningFontSize: merged.preferences.fontSize,
                      staleWriteRejected: true, clockReadByA: checked.preferences.terminalClockEnabled, fontSizeReadByA: checked.preferences.fontSize)
}
do { FileHandle.standardOutput.write(try JSONEncoder().encode(verify())) }
catch { fputs("Native sync check failed: " + error.localizedDescription + "\n", stderr); exit(1) }
