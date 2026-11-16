// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum AgentShellIntegration {
    static func bootstrap(token: String) -> String {
        // Load data through a silent read, not the interactive shell's editor/history.
        // The subshell owns its traps and restores the exact tty settings before eval.
        // Every transport line is a no-op if it arrives after a timeout/cancel.
        // Zsh does not enable interactive comments by default, so '#' is unsuitable.
        let end = ": OSHELL_END_" + token
        let loader = #"s=$(command stty -g) || exit; trap 'command stty "$s"' EXIT; trap 'exit 130' HUP INT TERM; command stty -echo || exit; p=; i=0; while [ "$i" -lt 64 ]; do builtin printf '\033]779;OSHELL;\#(token);load;%s\007' "$i" >&2; IFS= builtin read -r -t 5 l || exit; if [ "$l" = \#(AgentCommandPolicy.quote(end)) ]; then d=$(builtin printf %s "$p" | command base64 -d) || exit; builtin printf %s "$d"; exit; fi; [ "${l:0:2}" = ': ' ] || exit 1; p=$p${l:2}; i=$((i+1)); done; exit 1"#
        return #"if [ "${__oshell_mcp_version-}" = 2 ] && typeset -f __oshell_mcp_attach >/dev/null; then __oshell_mcp_attach \#(AgentCommandPolicy.quote(token)); else eval -- "$(\#(loader))"; fi"# + "\n"
    }

    static func payload(token: String) -> String {
        let bytes = Array(Data(script(token: token).utf8).base64EncodedString().utf8)
        // Below canonical input limits on both macOS and Linux; read joins the chunks.
        let lines = stride(from: 0, to: bytes.count, by: 384).map { offset in
            ": " + String(decoding: bytes[offset..<min(offset + 384, bytes.count)], as: UTF8.self)
        }
        return (lines + [endMarker(token: token)]).joined(separator: "\n") + "\n"
    }
    private static func endMarker(token: String) -> String { ": OSHELL_END_" + token }

    static func script(token: String) -> String {
        // PS0 supplies Bash's preexec boundary on 4.4+. The DEBUG fallback is only
        // used on older Bash and must not displace an existing debugger/preexec trap.
        #"""
        __oshell_mcp_supported=1;
        if [ -n "${BASH_VERSION-}" ]; then
            case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in 'declare -'*r*' PROMPT_COMMAND='*) __oshell_mcp_supported=0;; esac;
            if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
                case "$(trap -p DEBUG)" in ''|*__oshell_mcp_armed*) ;; *) __oshell_mcp_supported=0;; esac;
            fi;
        elif [ -z "${ZSH_VERSION-}" ]; then __oshell_mcp_supported=0;
        fi;
        if [ "$__oshell_mcp_supported" = 1 ]; then
            __oshell_mcp_token=\#(AgentCommandPolicy.quote(token)); __oshell_mcp_initializing=1; __oshell_mcp_armed=0;
            __oshell_mcp_attach() { __oshell_mcp_token=$1; __oshell_mcp_initializing=1; __oshell_mcp_armed=0; };
            __oshell_mcp_version=2;
            __oshell_mcp_start() { builtin printf '\033]779;OSHELL;%s;start\007' "$__oshell_mcp_token"; };
            __oshell_mcp_prompt() {
                local __oshell_mcp_status=$?;
                __oshell_mcp_armed=0;
                if [ "$__oshell_mcp_initializing" = 1 ]; then
                    __oshell_mcp_initializing=0;
                    builtin printf '\033]779;OSHELL;%s;ready\007' "$__oshell_mcp_token";
                else builtin printf '\033]779;OSHELL;%s;end;%s\007' "$__oshell_mcp_token" "$__oshell_mcp_status";
                fi;
                return "$__oshell_mcp_status";
            };
            __oshell_mcp_arm() { __oshell_mcp_armed=1; };
            if [ -n "${ZSH_VERSION-}" ]; then
                __oshell_mcp_zsh_prompt() { __oshell_mcp_prompt; return 0; };
                preexec_functions=(__oshell_mcp_start "${preexec_functions[@]:#__oshell_mcp_start}");
                precmd_functions=(__oshell_mcp_zsh_prompt "${precmd_functions[@]:#__oshell_mcp_zsh_prompt}");
            else
                if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; then
                    case "${PS0-}" in *'$( __oshell_mcp_start )'*) ;; *) PS0="${PS0-}"'$( __oshell_mcp_start )';; esac;
                else
                    trap 'if [ "${__oshell_mcp_armed-0}" = 1 ] && [ "$BASH_COMMAND" != __oshell_mcp_prompt ]; then __oshell_mcp_armed=0; __oshell_mcp_start; fi' DEBUG;
                fi;
                case "${PROMPT_COMMAND[*]-}" in *__oshell_mcp_prompt*) ;;
                    *)
                        if [ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; then
                            PROMPT_COMMAND=(__oshell_mcp_prompt "${PROMPT_COMMAND[@]}" __oshell_mcp_arm);
                        else PROMPT_COMMAND="__oshell_mcp_prompt${PROMPT_COMMAND:+$'\n'$PROMPT_COMMAND}"$'\n''__oshell_mcp_arm';
                        fi;
                        ;;
                esac;
            fi;
        else builtin printf '\033]779;OSHELL;%s;unsupported\007' \#(AgentCommandPolicy.quote(token));
        fi
        """#.replacingOccurrences(of: "\n", with: " ")
    }
}
