# Cascadia Code

Unmodified static TrueType faces from Microsoft's official [v2407.24 release](https://github.com/microsoft/cascadia-code/releases/tag/v2407.24): Regular, Bold, Italic and Bold Italic, extracted from `ttf/static/`.

- Archive: `CascadiaCode-2407.24.zip`
- Archive SHA-256: `e67a68ee3386db63f48b9054bd196ea752bc6a4ebb4df35adce6733da50c8474`
- License: SIL Open Font License 1.1; `LICENSE` is copied from the same upstream tag, with line endings normalized to LF.
- Individual file hashes: `SHA256SUMS.txt`.

OShell registers these fonts for its own process, without installing them into the user's font library. Static faces avoid depending on variable-font support and provide explicit regular, bold, italic and bold-italic styles for both release targets. The default terminal font remains unchanged. Bundling this font does not enable additional terminal ligature shaping.
