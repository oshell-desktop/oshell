// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum AIMarkdownTest {
    static func run() -> [String: Bool] {
        var checks = [String: Bool]()
        let escaped = #"资源整体平稳。依据：\n\n- **CPU / 负载：** 4 核，负载 0.07。\n- **内存：** `available` 1.44 GiB。\n- **磁盘：** `/dev/vda1` 已用 49%。\n\n范围说明：短时快照。"#
        let repaired = AIMarkdown.readableProse(escaped)
        checks["doubleEscapedReportHasRealParagraphs"] = repaired.contains("依据：\n\n- ") && !repaired.contains(#"\n"#)
        let protected = #"路径 C:\new\notes，正则 `\n+`，代码："# + "\n```sh\nprintf 'a\\nb'\n```"
        checks["repairPreservesPathsAndCode"] = AIMarkdown.readableProse(protected) == protected
        let report = AIMarkdown.blocks(repaired).compactMap { block -> String? in if case let .text(value) = block { return value.string }; return nil }.joined()
        checks["escapedReportRendersSeparateBullets"] = report.components(separatedBy: "•  ").count == 4 && !report.contains("**")
        let unfinished = "```sh\n" + #"printf 'a\n\n- b'"#
        checks["repairPreservesUnfinishedCode"] = AIMarkdown.readableProse(unfinished) == unfinished
        checks["displayRepairCannotChangeCommandParsing"] = AICommand.parse(#"说明\n\n```bash"# + "\n" + "printf ok" + "\n```").isEmpty
        let sample = """
        # 排查结果
        **Nginx 配置检查失败**，请先核对 `nginx.conf`，*不要直接重启*。

        ## 建议步骤
        1. 检查配置路径
        2. 验证配置语法
          - 保留当前连接
        - [x] 收集报错
        - [ ] 修复后验证

        > 这里只展示建议，不会自动执行命令。

        | 项目 | 状态 | 数量 |
        | :--- | :---: | ---: |
        | 配置 | **待检查** | 2 |
        | 服务 | 正在运行 | 1 |

        ```bash
        nginx -t
        ```

        命令后的说明应保持在原位置。参见 [官方文档](https://example.test/docs)。
        ~~旧建议~~ 已移除。

        ```json
        {"status": "waiting", "count": 2}
        ```
        """
        let blocks = AIMarkdown.blocks(sample)
        checks["markdownKeepsCodeAndProseOrder"] = blocks.count == 4 && {
            if case let .code(language, text, closed) = blocks[1] { return language == "bash" && text == "nginx -t" && closed }
            return false
        }()
        let texts = blocks.compactMap { block -> NSAttributedString? in if case let .text(text) = block { return text }; return nil }
        let first = texts.first!, last = texts.last!
        checks["markdownHeadingsListsQuotesAndTasks"] = first.string.contains("排查结果") && !first.string.contains("##") && first.string.contains("1.  检查") && first.string.contains("•  保留") && first.string.contains("☑") && first.string.contains("☐") && first.string.contains("▎")
        checks["markdownHeadingFont"] = (first.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 22
        let boldRange = (first.string as NSString).range(of: "Nginx 配置检查失败")
        let bold = first.attribute(.font, at: boldRange.location, effectiveRange: nil) as! NSFont
        checks["markdownEmphasisHasFontTraits"] = NSFontManager.shared.traits(of: bold).contains(.boldFontMask)
        let codeRange = (first.string as NSString).range(of: "nginx.conf")
        checks["markdownInlineCodeStyled"] = first.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) != nil
        var cells = [NSTextTableBlock]()
        first.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: first.length)) { value, _, _ in
            if let cell = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock { cells.append(cell) }
        }
        checks["markdownNativeTableHasAllCells"] = cells.count == 9 && cells.allSatisfy { $0.table.numberOfColumns == 3 }
        checks["markdownProseAfterCommandPreserved"] = last.string.contains("命令后的说明") && !last.string.contains("[官方文档]")
        let linkRange = (last.string as NSString).range(of: "官方文档")
        checks["markdownLinkIsExplicitURL"] = (last.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.test/docs"
        checks["markdownUnsafeLinksRejected"] = ["javascript:alert(1)", "file:///tmp/example", "oshell://connect", "https://user:pass@example.test", "data:text/html,test"].allSatisfy { AIMarkdown.safeLink($0) == nil }
        let untrusted = AIMarkdown.inline("![截图](https://example.test/private.png) <script>alert(1)</script> [运行](javascript:alert(1))")
        var attachment = false, unsafe = false
        untrusted.enumerateAttributes(in: NSRange(location: 0, length: untrusted.length)) { attrs, _, _ in
            attachment = attachment || attrs[.attachment] != nil
            if let url = attrs[.link] as? URL { unsafe = unsafe || AIMarkdown.safeLink(url.absoluteString) == nil }
        }
        checks["markdownDoesNotLoadImagesOrExecuteHTML"] = !attachment && !unsafe && untrusted.string.contains("图片：截图") && untrusted.string.contains("<script>")
        checks["markdownEscapesAndIdentifiers"] = AIMarkdown.inline("\\*literal\\* server_name `**literal**` 中文 😀").string == "*literal* server_name **literal** 中文 😀"
        checks["markdownBalancedLinkParentheses"] = AIMarkdown.inline("[docs](https://example.test/a_(b))").attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "https://example.test/a_(b)")
        checks["markdownLinkTitleIsNotURL"] = AIMarkdown.inline("[docs](https://example.test/docs \"Reference\")").attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "https://example.test/docs")
        checks["markdownLongFencesStayLiteral"] = AICommand.parse("````bash\necho '```'\n````").map(\.text) == ["echo '```'"]
        checks["markdownTildeFenceSupported"] = AICommand.parse("~~~sh\nprintf ok\n~~~").map(\.text) == ["printf ok"]
        checks["markdownUnclosedFenceNeverActionable"] = AICommand.parse("```bash\nprintf incomplete").isEmpty
        checks["markdownOtherCodeNeverActionable"] = AICommand.parse("```json\n{}\n```\n    rm -rf fixture").isEmpty
        let raw = "  printf 'a\\tb'\n\n# literal * characters"
        checks["markdownCodePreservesWhitespace"] = {
            if case let .code(_, source, _) = AIMarkdown.blocks("```python\n" + raw + "\n```").first! { return source == raw }; return false
        }()
        for width: CGFloat in [280, 396, 580] {
            let view = AIMarkdownTextView(first); view.setFrameSize(NSSize(width: width, height: 20))
            let height = view.intrinsicContentSize.height; view.setFrameSize(NSSize(width: width, height: height))
            checks["markdownFitsWidth:\(Int(width))"] = height > 200 && height < 2000 && view.layoutManager!.usedRect(for: view.textContainer!).maxX <= width + 1
            view.setSelectedRange(boldRange); _ = view.becomeFirstResponder()
            checks["markdownSelectionKeepsFormatting:\(Int(width))"] = view.isSelectable && !view.isEditable && (view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 22
        }
        let resize = AIMarkdownTextView(first)
        resize.setFrameSize(NSSize(width: 280, height: 20)); let narrow = resize.intrinsicContentSize.height
        resize.setFrameSize(NSSize(width: 580, height: narrow)); let wide = resize.intrinsicContentSize.height
        checks["markdownResizesWithoutClipping"] = narrow > wide
        return checks
    }
}
