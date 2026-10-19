// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum WebDAVCertificateDialog {
    static func confirm(_ issue: WebDAVCertificateIssue) -> Bool {
        guard issue.canTrust, issue.certificate.isCurrent() else { return false }
        let certificate = issue.certificate
        let date = DateFormatter(); date.dateStyle = .medium; date.timeStyle = .short
        let alert = PopupAlert()
        alert.messageText = issue.changed ? "服务器证书已更换，重新信任？" : "信任此 WebDAV 服务器证书？"
        alert.informativeText = "服务器：\(certificate.endpoint)\n证书主体：\(certificate.subject)\n颁发者：\(certificate.issuer)\n有效期：\(certificate.validFrom.map(date.string) ?? "未知") — \(certificate.validUntil.map(date.string) ?? "未知")\n\nSHA-256 指纹：\n\(certificate.fingerprint)\n\n请与服务器管理员提供的信息核对。确认后仅信任这台服务器的这张证书，证书更换需再次确认。点击设置页“应用”才会保存到本机加密设置中；其他 Mac 需独立确认。"
        if issue.requiresExplicitIPTrust {
            alert.informativeText += "\n\n当前按 IP 地址直连，证书不满足系统的 HTTPS 用途或名称规则。确认后以此 IP、端口和完整证书指纹识别服务器；不会信任其他证书或其他服务。"
        }
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "信任并重试")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
