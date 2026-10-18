// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import CoreText
import Foundation

/// Register once for this process only; never install into the user's font library.
enum BundledTerminalFonts {
    private static let registration: Void = {
        let families = [
            ("DejaVuFonts", ["DejaVuSansMono", "DejaVuSansMono-Bold", "DejaVuSansMono-Oblique", "DejaVuSansMono-BoldOblique"]),
            ("CascadiaCode", ["CascadiaCode-Regular", "CascadiaCode-Bold", "CascadiaCode-Italic", "CascadiaCode-BoldItalic"])
        ]
        for (directory, faces) in families {
            for name in faces {
                guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: directory) else { continue }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    static func register() { _ = registration }
}
