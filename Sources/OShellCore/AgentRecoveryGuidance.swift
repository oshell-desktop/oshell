// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A missing backend socket is not proof that the client's STDIO transport died.
public enum AgentRecoveryGuidance {
    public static func status(serviceEnabled: Bool, paired: Bool, connected: Bool, previouslyConnected: Bool) -> String {
        if !serviceEnabled { return "本机 MCP 服务未开启" }
        if !paired { return "尚未配对客户端" }
        if connected { return "本机通道已连接" }
        return previouslyConnected ? "本机通道暂未连接 · 等待客户端恢复" : "等待客户端首次连接"
    }
    public static let instructions = """
    1. 确认本机 MCP 服务已开启，并在此授权目标终端。OShell 重启或 SSH 重连后，需要重新授权；已有客户端配对无需重建。

    2. 本机通道暂未连接也可能只是空闲连接已释放。让客户端查询一次会话状态；辅助程序会在下一次请求时尝试恢复本机通道。

    3. 如果客户端明确提示 Transport closed，请在该客户端的 MCP 设置中重新连接 OShell 服务。OShell 无法替客户端重建已关闭的连接；不要反复关闭 OShell 服务或重新创建配对。

    4. 恢复后先查询原操作的状态和输出。断线不代表远端命令已停止或未执行，不要重新发送命令；保留原操作 ID 和幂等键。结果无法确认时，在终端或审计记录中核对，再继续操作。
    """
}
