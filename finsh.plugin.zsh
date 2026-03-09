# ─────────────────────────────────────────────────────────────────────────────
# finsh.zsh — Fish-inspired fuzzy tab completion for zsh
#
# Inspired by Fish shell's completion UX + ble.sh's implementation approach.
# Core idea: collect raw candidates at the ZLE layer, bypassing zsh's prefix
# filtering truncation entirely.
#
# Matching priority (descending; first match wins):
#   Pass 1  – exact prefix              "pi"      → pi-claude
#   Pass 2a – substring                 "claude"  → pi-claude
#   Pass 2b – head-anchored subsequence "piclaud" → pi-claude  (p anchored, iclaud ⊆ i-claude)
#   Pass 2c – pure subsequence          "pclaud"  → pi-claude  (*p*c*l*a*u*d*)
#
# Completion behaviour:
#   First Tab   – fuzzy filter → display candidate list via zle -M, no fill (show mode)
#   Type more   – live re-filter candidate list (remains in show mode)
#   Tab again   – fill first candidate, enter cycle mode
#   Cycle Tab   – cycle to next candidate (wraps around)
#   Shift+Tab   – native zsh completion (context-aware behaviour preserved)
#   Other keys  – accept current candidate, list disappears
#
# Completion scenarios:
#   Command name – collected from commands / functions / aliases / builtins
#   Subcommands  – with a registered completion function: use zle -C to establish
#                  a proper completion context, hook compadd to capture candidates
#                – without a registered completion function: parse $cmd --help output (state machine)
#   Paths        – glob current directory level, filter by filename component
# ─────────────────────────────────────────────────────────────────────────────

# ── Auto-initialise the completion system ────────────────────────────────────
# If compinit hasn't run yet ($_comps is empty), initialise automatically.
# On macOS, the Homebrew completion directory (_docker, _gh, etc.) is added to
# fpath automatically.
() {
    [[ -n "${_comps-}" ]] && return   # compinit already ran, skip
    if [[ "$OSTYPE" == darwin* ]]; then
        local _site="${HOMEBREW_PREFIX:-/opt/homebrew}/share/zsh/site-functions"
        [[ -d "$_site" ]] && (( ! ${fpath[(I)$_site]} )) && fpath=("$_site" $fpath)
    fi
    autoload -Uz compinit
    compinit -d ~/.zcompdump
}

# Global staging area for the compadd hook.
# (Functions called inside a completion context cannot access local variables
# from the outer widget.)
typeset -ga _FINSH_POOL

# Completion state (persists across widget invocations).
# First Tab: show mode — display list without filling; continue typing → live
# filter; Tab again → fill first candidate (cycle mode).
typeset -ga _FINSH_CANDS   # current candidate list (truncated to _FINSH_MAX_CANDS)
typeset -gi _FINSH_CANDS_PATH=0  # 1 = candidates are path basenames stored shell-quoted (${(q)})
typeset -gi _FINSH_IDX=0   # current selection index (1-based; 0 in show mode)
typeset -g  _FINSH_PFX=""  # content before the candidate word (fixed LBUFFER prefix during show mode)
: ${_FINSH_MAX_CANDS:=20}; typeset -gi _FINSH_MAX_CANDS  # max candidates; 0 = unlimited; set before sourcing to override
typeset -ga _FINSH_JUMP_CMDS; (( $#_FINSH_JUMP_CMDS )) || _FINSH_JUMP_CMDS=( j )  # jump command names; set before sourcing to override (e.g. _FINSH_JUMP_CMDS=(j z))
typeset -gi _FINSH_TOTAL=0       # total candidates before truncation (used for "+N more" hint)

# Show-mode state (entered on first Tab, exited and filled on second Tab).
typeset -gi _FINSH_SHOW_MODE=0      # 1 = show-without-fill mode
typeset -ga _FINSH_SHOW_POOL=()     # full candidate pool in show mode (for live re-filtering as user types)
typeset -g  _FINSH_SHOW_WORD_PFX="" # filter prefix (opts-only tools need "--" prepended to the current word)
typeset -g  _FINSH_RBUF=""          # RBUFFER to restore after filling a candidate (mid-line: strips right word part)

# Output array for _finsh_filter (avoids subshell; results written directly to global array).
typeset -ga _FINSH_FILTERED

# --help output cache (key=joined command words, value=help text; parsed at most once per session).
typeset -gA _FINSH_HELP_CACHE

# Output arrays for _finsh_parse_help (avoids subshell).
typeset -ga _FINSH_PARSE_SUBCMDS   # parsed subcommand list
typeset -ga _FINSH_PARSE_OPTS      # parsed --flag list

# History autosuggestion state.
typeset -g _FINSH_SUGGESTION=""         # current suggestion suffix (POSTDISPLAY content)
typeset -g _FINSH_SUGGESTION_NEEDLE=""  # last searched needle (avoids redundant searches)
typeset -gi _FINSH_HIST_SIZE=0          # history size at last sort (0 triggers initial sort on first search)
typeset -ga _FINSH_HIST_NUMS=()         # event numbers in descending order; rebuilt only when history grows

# Output variables for _finsh_collect_subcmd_pool (avoids subshell).
typeset -ga _FINSH_POOL_TMP=()   # collected candidate pool
typeset -gi _FINSH_REG_TMP=0     # whether a registered completion function exists (0/1)
typeset -g  _FINSH_WORD_TMP=""   # word possibly modified by the collector (opts-only tools prepend "--")

# Output variable for _finsh_re_escape (avoids subshell).
typeset -g  _FINSH_RE_ESCAPED=""

# Directory history for `j` completion (full paths, most-recently-visited first).
typeset -ga _FINSH_DIR_HIST=()
typeset -g  _FINSH_DIR_HIST_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/finsh/dir_hist"
[[ -f "$_FINSH_DIR_HIST_FILE" ]] && _FINSH_DIR_HIST=( ${(f)"$(<$_FINSH_DIR_HIST_FILE)"} )

# ── Comma-list helper ─────────────────────────────────────────────────────────
# Parse one comma-separated alias line from --help output and append valid
# subcommand tokens to _FINSH_PARSE_SUBCMDS.
# "    build, b  Compile the project" → appends "build" and "b"
# Called from _finsh_parse_help (subcmds + flat states) to avoid duplicating logic.
_finsh_parse_comma_list() {
    emulate -L zsh
    setopt extendedglob
    local _line="$1" _part
    local _trimmed="${_line##[[:space:]]#}"
    local _aliases_part="${_trimmed%%  *}"
    for _part in "${(s:,:)_aliases_part[@]}"; do
        _part="${_part##[[:space:]]#}"
        _part="${_part%%[[:space:]]*}"
        [[ "$_part" =~ '^[a-z][-a-z0-9]*$' ]] && _FINSH_PARSE_SUBCMDS+=("$_part")
    done
}

# ── ERE escape helper ────────────────────────────────────────────────────────
# Escape a string for literal use in POSIX ERE (=~ operator).
# Result written to _FINSH_RE_ESCAPED (avoids subshell).
#
# Why not ${(b)str}?  (b) escapes glob metacharacters only (* ? [ ] \).
# ERE additionally treats . + ( ) { } | ^ $ as metacharacters — these are
# NOT escaped by (b).  Use this helper wherever =~ patterns include dynamic
# content (e.g. a command name that might contain a dot: "node.js").
_finsh_re_escape() {
    emulate -L zsh   # no extendedglob: ( ) ^ { } | are literal in glob patterns
    local _s="$1"
    _s="${_s//\\/\\\\}"    # \ → \\ (must be first to avoid double-escaping)
    _s="${_s//./\\.}"      # .  literal in glob; ERE special
    _s="${_s//+/\\+}"      # +  literal in standalone glob; ERE special
    _s="${_s//\*/\\*}"     # *  glob special
    _s="${_s//\?/\\?}"     # ?  glob special
    _s="${_s//\(/\\(}"     # (  extendedglob special; \( = literal ( in all glob modes
    _s="${_s//\)/\\)}"     # )  extendedglob special; \) = literal )
    _s="${_s//\[/\\[}"     # [  glob special
    _s="${_s//\]/\\]}"     # ]  glob special
    _s="${_s//\^/\\^}"     # ^  extendedglob special; \^ = literal ^
    _s="${_s//$/\\$}"      # $  literal in glob; ERE special
    _s="${_s//|/\\|}"      # |  extendedglob in groups; ERE special
    _s="${_s//\{/\\{}"     # {  literal in glob; ERE quantifier
    _s="${_s//\}/\\\}}"    # }  literal in glob; ERE quantifier  (\\\} = \\ + \} where \} = literal })
    _FINSH_RE_ESCAPED="$_s"
}

# ── --help output parser ──────────────────────────────────────────────────────
# Input:  $1 = raw --help output text
# Output: results written to global arrays _FINSH_PARSE_SUBCMDS (subcommands)
#         and _FINSH_PARSE_OPTS (--flag options)
#
# Parsing strategy: single-pass state machine — classify section, then extract.
#
#   Initial state: flat (heuristic, suitable for tools without sections, e.g. git)
#
#   State transitions on section headers (line length ≤ 40 chars, starts with a letter):
#     *commands* / *subcommands* → subcmds (extract indented subcommands)
#     *options*  / *flags*       → opts    (extract --flags)
#     all-caps USAGE: / ARGS: …  → other   (skip entire section)
#
#   The line-length limit of 40 filters out long descriptive sentences (e.g. git's
#   "These are common Git commands used in various situations:"), preventing the
#   word "commands" inside a sentence from being mistaken for a section header.
#
#   Per-state extraction rules:
#     subcmds – 1-8 space indent + lowercase first word (section already scopes it;
#               simple rule suffices)
#               comma lists ("build, b  compile" style from npm/cargo) are also supported
#     opts    – --flag lines (with or without a -x, short-option prefix)
#     other   – skip all lines
#     flat    – extract both --flags and subcommands simultaneously
#               subcommands require 2-8 space indent + 2+ space gap after the name,
#               to filter out "  hx [FLAGS]..." USAGE lines (only 1 space after name)
#
#   Verified tools:
#     section-based: zig(2sp)  cargo(4sp,comma)  npm(comma)
#                    docker(multi-section)  hx(FLAGS:/USAGE:)
#                    pi/cobra (each line prefixed with program name: "  pi install <args>")
#     flat:          git(3sp, no section headers)
#
#   cobra/urfave style ($2 = command basename):
#     Commands section lines have the format "  <progname> <subcmd> [args...]".
#     When the first word equals $_cmdname, take the second word as the subcommand;
#     skip "<placeholder>" format (e.g. "pi <command> --help").
_finsh_parse_help() {
    emulate -L zsh
    setopt extendedglob
    local _help_out="$1"
    local _cmdname="${2:t}"  # command basename, used to recognise cobra-style "  pi subcmd" lines
    _finsh_re_escape "$_cmdname"
    local _cmdname_re="$_FINSH_RE_ESCAPED"   # ERE-escaped version for =~ patterns
    _FINSH_PARSE_SUBCMDS=()
    _FINSH_PARSE_OPTS=()
    [[ -z "$_help_out" ]] && return

    local _section="flat"
    local _line _lc
    while IFS= read -r _line; do

        # ── Section header detection ─────────────────────────────────────────
        # Condition: line length ≤ 40 (filter out long sentences) and starts with a letter
        if (( ${#_line} <= 40 )) && [[ "$_line" =~ '^[[:alpha:]]' ]]; then
            _lc="${_line:l}"   # lowercase for case-insensitive matching
            if   [[ "$_lc" =~ '(sub)?commands?[[:space:]]*:' ]]; then
                _section="subcmds"; continue
            elif [[ "$_lc" =~ '(options?|flags?)[[:space:]]*:' ]]; then
                _section="opts";    continue
            elif [[ "$_line" =~ '^[A-Z][A-Z -]*:' ]]; then
                # All-caps header (USAGE: ARGS: EXAMPLES: etc.)
                _section="other";   continue
            fi
        fi

        # ── Per-section extraction ───────────────────────────────────────────
        case "$_section" in

        subcmds)
            # Comma list (npm/cargo style: "  build, b  Compile...")
            if [[ "$_line" =~ '^[[:space:]]{1,8}[a-z][-a-z0-9]*,' ]]; then
                _finsh_parse_comma_list "$_line"
            # cobra style: first word is the program name; consume the whole line.
            # If the second word is a valid subcommand, extract it; otherwise (e.g.
            # "<placeholder>" format like "pi <command> --help") silently skip.
            elif [[ -n "$_cmdname" && "$_line" =~ '^[[:space:]]{1,8}'"${_cmdname_re}"'[[:space:]]' ]]; then
                [[ "$_line" =~ '^[[:space:]]{1,8}'"${_cmdname_re}"'[[:space:]]+([a-z][-a-z0-9]*)' ]] && \
                    _FINSH_PARSE_SUBCMDS+=("$match[1]")
            # Plain line: 1-8 space indent + lowercase first word (section already scopes it)
            elif [[ "$_line" =~ '^[[:space:]]{1,8}([a-z][-a-z0-9]*)' ]]; then
                _FINSH_PARSE_SUBCMDS+=("$match[1]")
            fi
            ;;

        opts)
            # --flag lines, with or without a -x, short-option prefix
            # (-[a-zA-Z0-9]+ supports multi-char short options like -nv, -nc, -4)
            if [[ "$_line" =~ '^[[:space:]]+((-[a-zA-Z0-9]+,?[[:space:]]+)?)(--([a-zA-Z][a-zA-Z0-9-]*))' ]]; then
                _FINSH_PARSE_OPTS+=("--$match[4]")
            fi
            ;;

        other) ;;   # USAGE: / ARGS: and other irrelevant sections — skip entirely

        flat)
            # Heuristic parsing (tools without sections, e.g. git)
            # --flag lines
            if [[ "$_line" =~ '^[[:space:]]+((-[a-zA-Z0-9]+,?[[:space:]]+)?)(--([a-zA-Z][a-zA-Z0-9-]*))' ]]; then
                _FINSH_PARSE_OPTS+=("--$match[4]")
            # Comma list
            elif [[ "$_line" =~ '^[[:space:]]{2,8}[a-z][-a-z0-9]*,' ]]; then
                _finsh_parse_comma_list "$_line"
            # cobra style: first word is the program name; if second word is a valid
            # subcommand (followed by 2+ spaces) extract it
            elif [[ -n "$_cmdname" && "$_line" =~ '^[[:space:]]{2,8}'"${_cmdname_re}"'[[:space:]]' ]]; then
                [[ "$_line" =~ '^[[:space:]]{2,8}'"${_cmdname_re}"'[[:space:]]+([a-z][-a-z0-9]*)[^[:space:]]*[[:space:]]{2,}' ]] && \
                    _FINSH_PARSE_SUBCMDS+=("$match[1]")
            # Plain line: 2-8 space indent + 2+ space gap after the name.
            # The 2+ space gap filters out "  cmd [ARG]..." USAGE lines (only 1 space after name).
            elif [[ "$_line" =~ '^[[:space:]]{2,8}([a-z][-a-z0-9]*)[^[:space:]]*[[:space:]]{2,}' ]]; then
                _FINSH_PARSE_SUBCMDS+=("$match[1]")
            fi
            ;;

        esac
    done <<< "$_help_out"
}

# ── Man page parser ───────────────────────────────────────────────────────────
# Last-resort fallback when --help is absent or yields no results;
# called by _finsh_collect_subcmd_pool.
# Output is written to global _FINSH_PARSE_SUBCMDS / _FINSH_PARSE_OPTS
# (shared with _finsh_parse_help).
#
# Key differences from the --help parser:
#   Section headers: all-uppercase without a colon (COMMANDS, OPTIONS,
#                    CLIENTS AND SESSIONS, etc.)
#   Subcommand extraction: name followed by " [" or end-of-line, to filter
#                          out descriptive lines like "target-session is tried as..."
#   Option extraction: double-dash --flag (when an OPTIONS section exists)
#                      + single-dash -x (detected in any section)
#
# BSD/macOS tools (ssh, cp, find, etc.) have no dedicated OPTIONS section;
# options are embedded in DESCRIPTION:
#   Format: 5-space indent + -x + 1+ spaces + description
#           (e.g. "     -4      Forces ssh to use IPv4")
#   Detecting this pattern in the "other" state is sufficient to collect them.
#
# Verified tools:
#   With OPTIONS section: grep (GNU), less
#   Without OPTIONS section: ssh (-4,-6,-A,...)  cp (-H,-L,-P,-R,...)
#   With COMMANDS section: custom CLIs that have a dedicated COMMANDS section
#   Not applicable (commands spread across sub-sections): tmux —
#     use `tmux list-commands` instead
_finsh_parse_man() {
    emulate -L zsh
    setopt extendedglob
    local _man_out="$1"
    _FINSH_PARSE_SUBCMDS=()
    _FINSH_PARSE_OPTS=()
    [[ -z "$_man_out" ]] && return

    local _section="other"
    local _line _lc

    while IFS= read -r _line; do

        # ── Section header: all-uppercase, no colon, line length ≤ 40 ────────
        # e.g. COMMANDS, OPTIONS, CLIENTS AND SESSIONS (length 20 ≤ 40)
        if [[ "$_line" =~ '^[A-Z][A-Z0-9 -]*$' ]] && (( ${#_line} <= 40 )); then
            _lc="${_line:l}"
            if   [[ "$_lc" =~ '(sub)?commands?' ]]; then _section="subcmds"
            elif [[ "$_lc" =~ '(options?|flags?)' ]]; then _section="opts"
            else _section="other"
            fi
            continue
        fi

        case "$_section" in

        subcmds)
            # 3-12 space indent + lowercase-hyphen name + " [" or end-of-line.
            # Requiring " [": filters out descriptive lines like
            # "     target-session is tried as, in order:".
            # Real tmux man page command entries look like:
            # "     attach-session [-dErx] ..."
            if [[ "$_line" =~ '^[[:space:]]{3,12}([a-z][-a-z0-9]*)( \[|$)' ]]; then
                _FINSH_PARSE_SUBCMDS+=("$match[1]")
            fi
            ;;

        opts)
            # Long options (with or without a -x, short-option prefix)
            if [[ "$_line" =~ '^[[:space:]]+((-[a-zA-Z0-9]+,?[[:space:]]+)?)(--([a-zA-Z][a-zA-Z0-9-]*))' ]]; then
                _FINSH_PARSE_OPTS+=("--$match[4]")
            # Single-dash short options (1-2 chars, followed by 1+ spaces)
            elif [[ "$_line" =~ '^[[:space:]]{3,12}(-[a-zA-Z0-9][a-zA-Z0-9]?)[[:space:]]+' ]]; then
                _FINSH_PARSE_OPTS+=("$match[1]")
            fi
            ;;

        other)
            # BSD tools embed options in DESCRIPTION (ssh, cp, etc. have no OPTIONS section).
            # Pattern: 3-12 space indent + -x or -xy (1-2 chars) + 1+ spaces.
            # e.g. ssh "     -4      Forces..."  cp "     -H    If the -R option..."
            # Note: -b bind_address (1 space) is also captured (option + argument-name format).
            if [[ "$_line" =~ '^[[:space:]]{3,12}(-[a-zA-Z0-9][a-zA-Z0-9]?)[[:space:]]+' ]]; then
                _FINSH_PARSE_OPTS+=("$match[1]")
            fi
            ;;

        esac
    done <<< "$_man_out"
}

# ── Multi-pass filter ─────────────────────────────────────────────────────────
# Results are written to global _FINSH_FILTERED to avoid $(...) subshell overhead.
# When word is empty, _FINSH_FILTERED is cleared; the caller should use the raw pool directly.
_finsh_filter() {
    emulate -L zsh
    local word="$1"; shift
    local -a pool=("$@")
    _FINSH_FILTERED=()

    [[ -z "$word" ]] && return

    # First-letter pre-filter: all passes require the candidate's first letter to
    # match word[1], preventing pure subsequence from matching large unrelated pools
    # (e.g. *p*i*c*l*i* hitting the entire command list).
    pool=( ${(M)pool:#${(b)word[1]}*} )
    (( $#pool )) || return

    local w="${(b)word}"   # escape glob metacharacters for literal matching
    local -a r

    # Pass 1 ── exact prefix
    r=( ${(M)pool:#${~w}*} )
    if (( $#r )); then _FINSH_FILTERED=( "${r[@]}" ); return; fi

    # Pass 2a ── substring
    r=( ${(M)pool:#*${~w}*} )
    if (( $#r )); then _FINSH_FILTERED=( "${r[@]}" ); return; fi

    # Pass 2b ── head-anchored subsequence (first letter literal, rest as subsequence glob)
    # Build "p*i*c*l*a*u*d*" for "piclaud"; zsh glob runs in C, avoiding per-element zsh loops.
    local head_pat="${(b)word[1]}" i
    for (( i = 2; i <= $#word; i++ )); do head_pat+="*${(b)word[i]}"; done
    head_pat+="*"
    r=( ${(M)pool:#${~head_pat}} )
    if (( $#r )); then _FINSH_FILTERED=( "${r[@]}" ); return; fi

    # Pass 2c ── pure subsequence
    local seq="*"
    for (( i = 1; i <= $#word; i++ )); do seq+="${(b)word[i]}*"; done
    _FINSH_FILTERED=( ${(M)pool:#${~seq}} )
}

# ── Candidate list display ────────────────────────────────────────────────────
# Shows all candidates below the prompt using zle -M; the current item is
# marked with [square brackets]. Long lines wrap automatically at terminal width.
_finsh_show_candidates() {
    emulate -L zsh
    local cols=${COLUMNS:-80}
    local -a out=()
    local line="" line_vis_len=0 i item item_vis_len

    for (( i = 1; i <= $#_FINSH_CANDS; i++ )); do
        local _cand_disp="${(Q)_FINSH_CANDS[$i]}"   # (Q) strips one level of shell quoting; no-op for plain strings
        item_vis_len=${#_cand_disp}
        if (( i == _FINSH_IDX )); then
            item="[${_cand_disp}]"
            (( item_vis_len += 2 ))   # two brackets each occupy 1 column
        else
            item="${_cand_disp}"
        fi

        if [[ -z "$line" ]]; then
            line="$item"
            line_vis_len=$item_vis_len
        elif (( line_vis_len + item_vis_len + 2 > cols )); then
            out+=("$line")
            line="$item"
            line_vis_len=$item_vis_len
        else
            line+="  $item"
            (( line_vis_len += item_vis_len + 2 ))
        fi
    done
    [[ -n "$line" ]] && out+=("$line")

    # Append a hint if the candidate list was truncated
    if (( _FINSH_TOTAL > $#_FINSH_CANDS )); then
        local _more="(+$(( _FINSH_TOTAL - $#_FINSH_CANDS )) more)"
        if (( $#out )); then
            out[-1]+="  $_more"
        else
            out=("$_more")
        fi
    fi

    zle -M -- "${(j:\n:)out}"
}

# ── compadd capture implementation ───────────────────────────────────────────
# Must be defined at the top level (global scope) so that the completion widget
# created by zle -C can call it.
#
# Key point: compadd can only be overridden by a function inside a completion
# context established with zle -C. Calling `zle complete-word` directly from a
# normal widget goes through the C layer and skips function lookup.
_finsh_capture() {
    emulate -L zsh
    # Override compadd inside the completion context to capture candidates into
    # the global staging area. We do NOT call builtin compadd — doing so would
    # write candidates into zsh's completion buffer, causing zsh to prompt
    # "do you wish to see all N possibilities?" after the context exits.
    # Always return 0 (simulate success) so completion functions don't fall
    # back to alternative branches and miss candidates.
    function compadd() {
        local i=1 skip_next=0
        while (( i <= $# )); do
            if (( skip_next )); then skip_next=0; (( i++ )); continue; fi
            case "${@[i]}" in
                # -O/-D/-A are internal array operations; skip the entire call
                -[ODA]) return 0 ;;
                # -a/-k: expand array / hash keys
                -a)  (( i++ )); [[ -n "${@[i]}" ]] && _FINSH_POOL+=( "${(@P)${@[i]}}" ) ;;
                -k)  (( i++ )); [[ -n "${@[i]}" ]] && _FINSH_POOL+=( "${(kP)${@[i]}}" ) ;;
                # Flags that take one argument: skip flag + argument
                # Per zsh manual compadd: -P -S -p -s -W -d -J -V -X -x -r -R -M -F -E -I -i
                # Also keeping -t -o (non-standard but seen in the wild); false positives are harmless
                -[PSpsWdJVXxrRMFtoEIi]) skip_next=1 ;;
                # Everything after -- is a candidate word
                --)  (( i++ )); _FINSH_POOL+=( "${@[$i,-1]}" ); return 0 ;;
                # Other flags (including combined flags like -qS, -ld, -QS, etc.)
                # If the flag string contains a character that takes an argument, set skip_next
                -*)  [[ "${@[i]}" =~ '[PSpsWdJVXxrRMFtoEIi]' ]] && skip_next=1 ;;
                # Actual candidate word
                *)   _FINSH_POOL+=( "${@[i]}" ) ;;
            esac
            (( i++ ))
        done
        return 0
    }

    # Trigger completion in priority order
    if   (( ${+functions[_main_complete]} )); then _main_complete
    elif (( ${+functions[_complete]}      )); then _complete
    else
        # Call the command's completion function directly (bypass dispatcher)
        local _cmd="${words[1]-}" _cfunc="${_comps[${words[1]-}]-}"
        [[ -n "$_cfunc" ]] && "$_cfunc"
    fi
    # unfunction compadd is handled by the widget's always block; no need to repeat here
}

# ── Path completion ───────────────────────────────────────────────────────────
# Called when word contains /. Returns 0 if handled (widget should return),
# or 1 if the word is not a path (caller continues).
# Reads:  $1=word, $2=prefix (unchanged portion before the cursor)
# Writes: _FINSH_CANDS / _FINSH_PFX / _FINSH_IDX / LBUFFER (ZLE state)
_finsh_try_path() {
    emulate -L zsh
    setopt extendedglob nullglob
    local _word="$1" _prefix="$2"
    [[ "$_word" == */* ]] || return 1

    local dir base
    if [[ "$_word" == */ ]]; then
        dir="${_word%/}"
        base=""
    else
        dir="${_word:h}"
        base="${_word:t}"
    fi
    # When base is empty (trailing slash), fall back to native completion.
    # When base is less than 1 character, do nothing.
    (( ${#base} >= 1 )) || { [[ "$_word" == */ ]] && zle complete-word; return 0; }

    local xdir="${dir/#\~/$HOME}"   # expand ~ (~ does not expand inside double quotes)
    local sep="${dir%/}/"           # normalise separator: strip trailing / then add it back,
                                    # avoiding double slashes when dir="/"
    local xbase="${xdir%/}"         # strip trailing / to prevent "//" in path concatenation
    local -a names
    if [[ -z "$xbase" ]]; then
        names=( /*(.DN) /*(/DN) /*(@DN) )     # root dir: glob directly, results are /Applications etc.
    else
        names=( "${xbase}"/*(.DN) "${xbase}"/*(/DN) "${xbase}"/*(@DN) )
    fi
    names=( "${names[@]#${xbase}/}" )  # strip directory prefix, keep only filenames

    if (( $#names == 0 )); then zle complete-word; return 0; fi

    _finsh_filter "$base" "${names[@]}"
    # When base is empty (word="dir/") show all files in the directory;
    # when base is non-empty but nothing matched, show everything
    # (path pools are typically small)
    local -a show
    if (( $#_FINSH_FILTERED )); then
        show=("${_FINSH_FILTERED[@]}")
    else
        show=("${names[@]}")
    fi

    if (( $#show == 1 )); then
        LBUFFER="${_prefix}${sep}${(q)show[1]}"   # (q): escape spaces and shell metacharacters in filename
        RBUFFER="$_FINSH_RBUF"
        zle reset-prompt
        return 0
    fi

    _FINSH_TOTAL=$#show
    (( _FINSH_MAX_CANDS > 0 && $#show > _FINSH_MAX_CANDS )) && show=( "${(@)show[1,$_FINSH_MAX_CANDS]}" )
    _FINSH_CANDS=( "${(@q)show}" )   # store shell-quoted form; display strips (Q); cycle/fill uses directly
    _FINSH_CANDS_PATH=1              # signal: candidates are quoted path basenames
    _FINSH_PFX="${_prefix}${sep}"
    _FINSH_IDX=0
    _FINSH_SHOW_MODE=1
    _FINSH_SHOW_POOL=( "${names[@]}" )   # save full RAW filename pool for live re-filtering
    _FINSH_SHOW_WORD_PFX=""              # path completion needs no word-prefix transformation
    _finsh_show_candidates
    return 0
}

# ── Subcommand / option candidate collection ──────────────────────────────────
# Input:  $1=word, $2=prefix (portion before the cursor)
# Output written to global variables (avoids subshell):
#   _FINSH_POOL_TMP  – collected candidate pool
#   _FINSH_REG_TMP   – whether a registered completion function exists (0/1)
#   _FINSH_WORD_TMP  – word possibly modified (opts-only tools get "--" prepended)
#
# The --help path is attempted in three situations:
#   ① No registered completion function (e.g. zig, hx before installation)
#   ② Registered function exists but the hook captured nothing — _arguments-based
#      functions (e.g. _hx) use the comparguments C builtin, which bypasses the
#      function-level compadd hook, leaving the pool permanently empty
#   ③ word starts with - but all hooked candidates are non-option values
#      (e.g. _wget's _urls → _files)
_finsh_collect_subcmd_pool() {
    emulate -L zsh
    local _word="$1" _prefix="$2"
    _FINSH_POOL_TMP=()
    _FINSH_REG_TMP=0
    _FINSH_WORD_TMP="$_word"

    local _cmd="${${(Az)_prefix}[1]-}"

    # ── j: complete from directory history ───────────────────────────────────
    # Expand every recorded path into all its components so that any level can
    # be matched: history has /Users/edh/dev/shell/finsh → pool includes
    # "Users", "edh", "dev", "shell", "finsh" (empty leading segment filtered).
    # Pool format: "component  [/path/prefix]" for every (component, ancestor)
    # pair derived from _FINSH_DIR_HIST.  The component is at the front so the
    # first-letter pre-filter and prefix matching work normally.  After the user
    # selects a candidate, j() extracts the path from the brackets and cds there.
    if (( ${_FINSH_JUMP_CMDS[(I)$_cmd]} )); then
        if (( $#_FINSH_DIR_HIST == 0 )); then
            zle -M -- "j: no directory history"
            return
        fi
        local -a _j_pool=() _jparts=()
        local _jd _jseg _jpath _ji
        for _jd in "${_FINSH_DIR_HIST[@]}"; do
            _jparts=( ${(s:/:)_jd} )
            for (( _ji = 1; _ji <= ${#_jparts}; _ji++ )); do
                _jseg="${_jparts[$_ji]}"
                [[ -z "$_jseg" ]] && continue
                _jpath="/${(j:/:)_jparts[1,$_ji]}"
                [[ "$_jpath" == "$HOME"* ]] && _jpath="~${_jpath#$HOME}"
                _j_pool+=( "${_jseg} → ${_jpath}" )
            done
        done
        _FINSH_POOL_TMP=( ${(u)_j_pool} )
        return
    fi

    if [[ -n "${_comps[$_cmd]-}" ]]; then
        # ── Registered completion function: use the zle -C capture path ──────
        _FINSH_REG_TMP=1
        # Use zle -C to establish a proper completion context; inside this
        # context, compadd can be overridden by a function.
        _FINSH_POOL=()
        zle -C _finsh_cap complete-word _finsh_capture
        local slbuf=$LBUFFER srbuf=$RBUFFER
        {
            # Remove the current word so zsh generates a full candidate list
            # from context with an empty word
            LBUFFER="$_prefix"
            RBUFFER=""
            CURSOR=${#LBUFFER}
            zle _finsh_cap 2>/dev/null
        } always {
            LBUFFER="$slbuf"
            RBUFFER="$srbuf"
            zle -D _finsh_cap 2>/dev/null
            unfunction compadd 2>/dev/null   # clean up in case of abnormal exit
        }
        _FINSH_POOL_TMP=( "${_FINSH_POOL[@]}" )
        _FINSH_POOL=()
    fi

    # ── compadd captured nothing, or no registered function: parse $cmd --help ─
    if [[ -n "$_cmd" ]] && {
        (( $#_FINSH_POOL_TMP == 0 )) ||
        { [[ "$_word" == -* ]] && (( ${#${(M)_FINSH_POOL_TMP:#-*}} == 0 )) }
    }; then
        _FINSH_POOL_TMP=()   # discard irrelevant candidates (e.g. filenames); use --help results instead
        local -a _help_words=()
        local _w
        for _w in ${(Az)_prefix}; do
            [[ "$_w" == -* ]] || _help_words+=("$_w")
        done

        # Cache key = joined command words; same subcommand path is only forked once per session
        local _cache_key="${(j: :)_help_words}"
        local _help_out
        if [[ -n "${_FINSH_HELP_CACHE[$_cache_key]+x}" ]]; then
            _help_out="${_FINSH_HELP_CACHE[$_cache_key]}"
        else
            _help_out="$(command "${_help_words[@]}" --help 2>&1)"
            _FINSH_HELP_CACHE[$_cache_key]="$_help_out"
        fi

        if [[ -n "$_help_out" ]]; then
            _finsh_parse_help "$_help_out" "${_help_words[1]}"
            if [[ "$_word" == -* ]]; then
                _FINSH_POOL_TMP=( "${_FINSH_PARSE_OPTS[@]}" )
            elif (( $#_FINSH_PARSE_SUBCMDS )); then
                _FINSH_POOL_TMP=( "${_FINSH_PARSE_SUBCMDS[@]}" )
            elif (( $#_FINSH_PARSE_OPTS )); then
                # No subcommands but options exist (e.g. node, hx).
                # Route to the opts pool; prepend "--" to a non-empty word so
                # that "bu" can match "--build-sea".
                _FINSH_POOL_TMP=( "${_FINSH_PARSE_OPTS[@]}" )
                [[ -n "$_word" ]] && _FINSH_WORD_TMP="--${_word}"
            fi
        fi
    fi

    # ── --help yielded nothing: try parsing the man page ─────────────────────
    # Applicable when: --help is absent (BSD/POSIX tools like ssh, cp, find)
    # or --help only outputs a usage line with nothing parseable.
    # Man page options are typically single-dash -x; the user must explicitly
    # type "-" to route to the options pool (the "--" prefix trick is not applied).
    # Note: tmux commands are spread across sub-sections (CLIENTS AND SESSIONS, etc.)
    # rather than a COMMANDS section — man parsing is ineffective for tmux;
    # use `tmux list-commands` instead.
    #
    # Shared globals note: _finsh_parse_man writes to the same _FINSH_PARSE_SUBCMDS
    # and _FINSH_PARSE_OPTS arrays as _finsh_parse_help (both clear them at the
    # start).  This is safe here because we only reach this path when
    # _FINSH_POOL_TMP is empty — the parse_help results (if any) were already
    # consumed into _FINSH_POOL_TMP above.  Do NOT call both parsers and expect
    # both sets of results to coexist in those globals simultaneously.
    if [[ -n "$_cmd" ]] && (( $#_FINSH_POOL_TMP == 0 )); then
        local _man_cache_key="man:${_cmd}"
        local _man_out
        if [[ -n "${_FINSH_HELP_CACHE[$_man_cache_key]+x}" ]]; then
            _man_out="${_FINSH_HELP_CACHE[$_man_cache_key]}"
        else
            _man_out="$(man -P cat "$_cmd" 2>/dev/null | col -bx)"
            _FINSH_HELP_CACHE[$_man_cache_key]="$_man_out"
        fi
        if [[ -n "$_man_out" ]]; then
            _finsh_parse_man "$_man_out"
            if [[ "$_word" == -* ]]; then
                _FINSH_POOL_TMP=( "${_FINSH_PARSE_OPTS[@]}" )
            elif (( $#_FINSH_PARSE_SUBCMDS )); then
                _FINSH_POOL_TMP=( "${_FINSH_PARSE_SUBCMDS[@]}" )
            # Man page options are single-dash -x; no "--" prefix routing
            # (user must type "-" explicitly to complete options)
            fi
        fi
    fi
}

# ── ZLE widget ────────────────────────────────────────────────────────────────
_finsh_complete() {
    emulate -L zsh
    setopt extendedglob nullglob

    # ── Tab in show mode: fill first candidate, enter cycle mode ─────────────
    # Does not rely on LASTWIDGET (the user may have typed characters during show mode)
    if (( _FINSH_SHOW_MODE )) && (( $#_FINSH_CANDS )); then
        _FINSH_SHOW_MODE=0
        _FINSH_SHOW_POOL=()
        _FINSH_SHOW_WORD_PFX=""
        _FINSH_IDX=1
        LBUFFER="${_FINSH_PFX}${_FINSH_CANDS[1]}"
        RBUFFER="$_FINSH_RBUF"
        _finsh_show_candidates
        return
    fi

    # ── Tab in cycle mode: advance to the next candidate ─────────────────────
    if [[ "$LASTWIDGET" == "_finsh_complete" ]] && (( $#_FINSH_CANDS )) \
        && [[ "$LBUFFER" == "${_FINSH_PFX}${_FINSH_CANDS[$_FINSH_IDX]}" ]]; then
        _FINSH_IDX=$(( (_FINSH_IDX % $#_FINSH_CANDS) + 1 ))
        LBUFFER="${_FINSH_PFX}${_FINSH_CANDS[$_FINSH_IDX]}"
        _finsh_show_candidates
        return
    fi

    # ── New completion round: reset all state ─────────────────────────────────
    _FINSH_SHOW_MODE=0
    _FINSH_SHOW_POOL=()
    _FINSH_SHOW_WORD_PFX=""
    _FINSH_CANDS=()
    _FINSH_IDX=0
    _FINSH_PFX=""
    _FINSH_RBUF=""
    _FINSH_CANDS_PATH=0

    local lbuf=$LBUFFER

    # ── Compute the right part of the current word in RBUFFER (mid-line) ─────
    # When the cursor is inside a word (e.g. "--dr|y-run"), RBUFFER starts with
    # the remainder of that word ("y-run ...").  Strip those leading non-space
    # characters so that after filling a candidate the buffer is clean.
    # When the cursor is already at a word boundary (space or end-of-line) this
    # simply sets _FINSH_RBUF equal to the full RBUFFER.
    local _rword=""
    [[ "$RBUFFER" =~ '^([^[:space:]]*)' ]] && _rword="$match[1]"
    _FINSH_RBUF="${RBUFFER[${#_rword}+1,-1]}"

    local word prefix

    # Trailing whitespace → cursor is at the start of a new word; current word is empty
    if [[ "$lbuf" =~ '[[:space:]]$' ]] || [[ -z "$lbuf" ]]; then
        word=""; prefix="$lbuf"
    else
        local words=(${(z)lbuf})
        word="${words[-1]:-''}"
        prefix="${lbuf[1,-${#word}-1]}"   # index-based: avoids glob matching (~ and other metacharacters)
    fi

    # ── Path completion ───────────────────────────────────────────────────────
    if [[ "$word" == */* ]]; then
        _finsh_try_path "$word" "$prefix"
        return
    fi

    # Command name / subcommand / option completion: don't trigger on fewer than 1 character
    (( ${#word} >= 1 )) || return

    local -a pool=()
    local _registered=0
    local raw_word="$word"   # save the original word before _finsh_collect_subcmd_pool may modify it

    # ── Command name completion ───────────────────────────────────────────────
    if [[ "$prefix" =~ '^[[:space:]]*$' ]]; then
        pool=(
            ${(k)commands}
            ${(k)functions[(I)[^_]*]}
            ${(k)aliases}
            ${(k)builtins}
        )

    # ── Subcommand / option completion ───────────────────────────────────────
    else
        _finsh_collect_subcmd_pool "$word" "$prefix"
        pool=( "${_FINSH_POOL_TMP[@]}" )
        _registered=$_FINSH_REG_TMP
        word="$_FINSH_WORD_TMP"
    fi

    # opts-only tools prepend "--" to word (e.g. "bu" → "--bu");
    # record the prefix for show-mode re-filtering
    _FINSH_SHOW_WORD_PFX=""
    (( ${#word} > ${#raw_word} )) && _FINSH_SHOW_WORD_PFX="${word[1,${#word}-${#raw_word}]}"

    pool=( ${(u)pool} )   # deduplicate

    if (( $#pool == 0 )); then
        # Registered completion function but pool is empty: the function ran and
        # produced no results (e.g. just in a directory without a justfile).
        #   → exit silently; do not fall back to zle complete-word to avoid
        #     producing incorrect completions.
        # No registered function and --help also yielded nothing: fall back to
        # native completion (usually file completion).
        (( _registered )) || zle complete-word
        return
    fi

    # ── Multi-pass filtering ──────────────────────────────────────────────────
    _finsh_filter "$word" "${pool[@]}"
    local -a show
    if (( $#_FINSH_FILTERED )); then
        show=("${_FINSH_FILTERED[@]}")
    elif [[ -z "$word" ]]; then
        show=("${pool[@]}")   # show everything when word is empty (e.g. command list)
    else
        return   # input present but no match — exit silently, let the user keep typing
    fi

    # Unique candidate: fill it directly without showing a list
    if (( $#show == 1 )); then
        LBUFFER="${prefix}${show[1]}"
        RBUFFER="$_FINSH_RBUF"
        zle reset-prompt
        return
    fi

    # ── Enter show mode: display candidate list without filling anything ──────
    # The user can continue typing to live-filter; Tab again fills the first
    # candidate and enters cycle mode.
    _FINSH_TOTAL=$#show
    (( _FINSH_MAX_CANDS > 0 && $#show > _FINSH_MAX_CANDS )) && show=( "${(@)show[1,$_FINSH_MAX_CANDS]}" )
    _FINSH_CANDS=( "${show[@]}" )
    _FINSH_PFX="$prefix"
    _FINSH_IDX=0
    _FINSH_SHOW_MODE=1
    _FINSH_SHOW_POOL=( "${pool[@]}" )   # save deduplicated full candidate pool
    # LBUFFER is left unchanged
    _finsh_show_candidates
}

# ── History autosuggestion ────────────────────────────────────────────────────
# Searches $history from the most recent entry backwards for the first command
# that starts with needle and is longer than needle.
# Result is written to global _FINSH_SUGGESTION (avoids subshell overhead).
_finsh_search_history() {
    local needle="$1"
    _FINSH_SUGGESTION=""
    [[ -z "$needle" ]] && return

    # Rebuild the sorted event-number list only when history has grown (once per accepted
    # command), not on every pre-redraw keystroke.  Avoids O(n log n) re-sort on every key.
    if (( $#history != _FINSH_HIST_SIZE )); then
        _FINSH_HIST_NUMS=( ${(Onk)history} )   # no outer quotes — see AGENTS.md Bug 13
        _FINSH_HIST_SIZE=$#history
    fi

    local num entry
    for num in "${_FINSH_HIST_NUMS[@]}"; do
        entry="${history[$num]}"
        if [[ "$entry" == "${needle}"* ]] && [[ "$entry" != "$needle" ]]; then
            _FINSH_SUGGESTION="${entry#$needle}"
            return
        fi
    done
}

# Refresh POSTDISPLAY + region_highlight.
# Not updated during the completion cycle (zeroed by _finsh_pre_redraw);
# hidden when cursor is not at end of line.
# When LBUFFER is unchanged, reuse the cache to avoid re-sorting $history on every pre-redraw.
_finsh_update_suggestion() {
    emulate -L zsh
    # Clear old highlights (memo=finsh-sug identifies entries owned by this plugin)
    region_highlight=( ${region_highlight:#*memo=finsh-sug} )

    if (( $#_FINSH_CANDS )) || (( CURSOR != ${#BUFFER} )); then
        POSTDISPLAY=""
        return
    fi

    # LBUFFER unchanged: reuse cached suggestion
    if [[ "$LBUFFER" != "$_FINSH_SUGGESTION_NEEDLE" ]]; then
        _finsh_search_history "$LBUFFER"
        _FINSH_SUGGESTION_NEEDLE="$LBUFFER"
    fi

    POSTDISPLAY="$_FINSH_SUGGESTION"
    if [[ -n "$_FINSH_SUGGESTION" ]]; then
        local p=${#BUFFER}
        region_highlight+=( "${p} $((p + ${#_FINSH_SUGGESTION})) fg=8 memo=finsh-sug" )
    fi
}

# Right arrow: accept the full suggestion when one is shown; otherwise fall
# back to ordinary forward-char.
_finsh_autosuggest_accept() {
    emulate -L zsh
    if [[ -n "$POSTDISPLAY" ]]; then
        LBUFFER="${LBUFFER}${POSTDISPLAY}"
        POSTDISPLAY=""
        region_highlight=( ${region_highlight:#*memo=finsh-sug} )
        _FINSH_SUGGESTION=""
        _FINSH_SUGGESTION_NEEDLE="$LBUFFER"
    else
        zle forward-char
    fi
}
zle -N _finsh_autosuggest_accept

# ── Wrap accept-line: clear suggestion before final render ────────────────────
# zle-line-finish fires after ZLE has finished the final render, so clearing
# POSTDISPLAY there is too late. We must clear it the moment accept-line is
# called to prevent the grey suggestion text from being printed to the terminal
# along with the accepted line.
#
# Root cause: zle-line-pre-redraw fires once more after accept-line, triggering
# _finsh_update_suggestion again. If _FINSH_SUGGESTION_NEEDLE were reset to "",
# update-sug would see LBUFFER != needle, re-search history, write the suggestion
# back to POSTDISPLAY, and the grey text would appear in the final render.
# Fix: set needle to the current LBUFFER (not ""), so update-sug hits the cache
# and reuses the already-cleared _FINSH_SUGGESTION="", keeping POSTDISPLAY empty.
#
# Plugin chaining: save whatever accept-line currently resolves to (built-in or
# another plugin's wrapper) before we override it.  Our wrapper calls the saved
# widget via `zle _finsh_orig_accept_line`, forming a correct chain regardless
# of load order:
#   other-plugin-before → _finsh_accept_line → _finsh_orig_accept_line(=other-before)
#   other-plugin-after  → other-after → _finsh_orig_accept_line(=_finsh_accept_line) → built-in
# Using `.accept-line` (the hard-coded built-in) would bypass every other
# plugin's wrapper and break the chain.
# Guard: only capture the real accept-line once; re-sourcing would otherwise
# make _finsh_orig_accept_line point back to _finsh_accept_line → infinite loop.
(( ${+widgets[_finsh_orig_accept_line]} )) || zle -A accept-line _finsh_orig_accept_line
_finsh_accept_line() {
    emulate -L zsh
    POSTDISPLAY=""
    region_highlight=( ${region_highlight:#*memo=finsh-sug} )
    _FINSH_SUGGESTION=""
    _FINSH_SUGGESTION_NEEDLE="$LBUFFER"   # lock needle to prevent pre-redraw from re-searching history
    zle _finsh_orig_accept_line
}
zle -N accept-line _finsh_accept_line

# ── Show-mode exit helper ─────────────────────────────────────────────────────
# Resets all show-mode state and clears the candidate menu.
# Called from _finsh_pre_redraw in three exit paths: backspace into prefix
# region, word too short, and no filter match.
_finsh_exit_show_mode() {
    _FINSH_SHOW_MODE=0; _FINSH_SHOW_POOL=(); _FINSH_SHOW_WORD_PFX=""
    _FINSH_CANDS=(); _FINSH_IDX=0; _FINSH_PFX=""; _FINSH_CANDS_PATH=0
    zle -M ""
    _finsh_update_suggestion
}

# ── Auto-clear candidate menu ─────────────────────────────────────────────────
# zle-line-pre-redraw fires before every redraw. If the last widget was not this
# one, the user performed some other action (Backspace, typing, arrow keys, etc.),
# so we clear the menu and cycle state.
_finsh_pre_redraw() {
    emulate -L zsh
    if [[ "$LASTWIDGET" == "_finsh_complete" ]]; then
        # During the completion cycle (including the first Tab that enters show
        # mode): clear suggestion but keep the candidate menu
        POSTDISPLAY=""
        region_highlight=( ${region_highlight:#*memo=finsh-sug} )
        return
    fi

    # ── Show mode: live re-filter candidate list as the user types ────────────
    if (( _FINSH_SHOW_MODE )) && (( $#_FINSH_SHOW_POOL )); then
        # Extract the current word by stripping the fixed _FINSH_PFX portion
        local _sm_cur_word=""
        if [[ "${LBUFFER[1,${#_FINSH_PFX}]}" == "$_FINSH_PFX" ]]; then
            _sm_cur_word="${LBUFFER[${#_FINSH_PFX}+1,-1]}"
        else
            # User backspaced into the prefix region: exit show mode
            _finsh_exit_show_mode
            return
        fi

        # Current word shorter than 1 character: exit show mode (user backspaced)
        if (( ${#_sm_cur_word} < 1 )); then
            _finsh_exit_show_mode
            return
        fi

        # Apply the "--" prefix for opts-only tools (so "bu" can match "--build")
        local _sm_filter_word="${_FINSH_SHOW_WORD_PFX}${_sm_cur_word}"

        _finsh_filter "$_sm_filter_word" "${_FINSH_SHOW_POOL[@]}"
        local -a _sm_show
        if (( $#_FINSH_FILTERED )); then
            _sm_show=("${_FINSH_FILTERED[@]}")
        elif [[ -z "$_sm_filter_word" ]]; then
            _sm_show=("${_FINSH_SHOW_POOL[@]}")
        else
            # No match: exit show mode and clear the candidate list
            _finsh_exit_show_mode
            return
        fi

        # Update and display the candidate list
        # (_FINSH_IDX=0 → no bracket highlight; no selection in show mode)
        _FINSH_TOTAL=$#_sm_show
        (( _FINSH_MAX_CANDS > 0 && $#_sm_show > _FINSH_MAX_CANDS )) && _sm_show=( "${(@)_sm_show[1,$_FINSH_MAX_CANDS]}" )
        # Path candidates are stored shell-quoted in _FINSH_CANDS so that cycle/fill can use them directly
        if (( _FINSH_CANDS_PATH )); then
            _FINSH_CANDS=( "${(@q)_sm_show}" )
        else
            _FINSH_CANDS=( "${_sm_show[@]}" )
        fi
        _FINSH_IDX=0
        POSTDISPLAY=""
        region_highlight=( ${region_highlight:#*memo=finsh-sug} )
        _finsh_show_candidates
        return
    fi

    if (( $#_FINSH_CANDS )); then
        _FINSH_SHOW_MODE=0; _FINSH_SHOW_POOL=(); _FINSH_SHOW_WORD_PFX=""
        _FINSH_CANDS=()
        _FINSH_IDX=0
        _FINSH_PFX=""
        _FINSH_CANDS_PATH=0
        zle -M ""
    fi
    _finsh_update_suggestion
}
autoload -Uz add-zle-hook-widget
add-zle-hook-widget zle-line-pre-redraw _finsh_pre_redraw

# ── Directory history hook ────────────────────────────────────────────────────
# Prepend the full path of the new directory to _FINSH_DIR_HIST on every `cd`.
# Deduplicates (most-recently-visited first); capped at 500 entries; persisted to file.
_finsh_chpwd() {
    [[ "$PWD" == "/" ]] && return
    _FINSH_DIR_HIST=( "$PWD" ${_FINSH_DIR_HIST:#$PWD} )
    (( $#_FINSH_DIR_HIST > 500 )) && _FINSH_DIR_HIST=( "${_FINSH_DIR_HIST[1,500]}" )
    print -l "${_FINSH_DIR_HIST[@]}" >| "$_FINSH_DIR_HIST_FILE"
}
autoload -Uz add-zsh-hook
[[ -d "${_FINSH_DIR_HIST_FILE:h}" ]] || mkdir -p "${_FINSH_DIR_HIST_FILE:h}"
add-zsh-hook chpwd _finsh_chpwd

# ── Directory jump implementation ─────────────────────────────────────────────
# Called by every command listed in _FINSH_JUMP_CMDS (default: j).
# Usage: <cmd> [term]
#   no args  → cd ~
#   term     → resolution order:
#               1. completion candidate "component  [/full/path]" → cd to path
#               2. direct path (absolute or ~-prefixed)
#               3. exact component match at any path level, deepest first
#                  (j finsh → /Users/edh/dev/shell/finsh)
#                  (j shell → /Users/edh/dev/shell)
#               4. substring match on full path (fallback)
#              Most-recently-visited wins when multiple paths match.
_finsh_jump() {
    if (( $# == 0 )); then
        cd ~
        return
    fi
    local _q="$1"
    # Candidate filled by completion: "component → /full/path"
    # Search for → at any argument position so that paths containing spaces
    # (which the shell splits into multiple words) are correctly reassembled.
    local _arrow_idx=0 _ai
    for (( _ai = 2; _ai <= $#; _ai++ )); do
        [[ "${@[$_ai]}" == "→" ]] && { _arrow_idx=$_ai; break; }
    done
    if (( _arrow_idx > 0 && _arrow_idx < $# )); then
        local _d3="${(j: :)@[$_arrow_idx+1,-1]}"
        _d3="${_d3/#\~/$HOME}"
        [[ -d "$_d3" ]] && { cd "$_d3"; return; }
    fi
    # Direct path (absolute or ~-prefixed)
    local _qexp="${_q/#\~/$HOME}"
    if [[ -d "$_qexp" ]]; then
        cd "$_qexp"
        return
    fi
    # Exact component match at any depth (deepest component wins within a path;
    # most-recently-visited path wins across paths).
    local _d _i _target
    local -a _parts
    for _d in "${_FINSH_DIR_HIST[@]}"; do
        _parts=( ${(s:/:)_d} )
        for (( _i = ${#_parts}; _i >= 1; _i-- )); do
            if [[ "${_parts[$_i]}" == "$_q" ]]; then
                _target="/${(j:/:)_parts[1,$_i]}"
                [[ -d "$_target" ]] && { cd "$_target"; return; }
                break
            fi
        done
    done
    # Substring match on full path
    for _d in "${_FINSH_DIR_HIST[@]}"; do
        [[ "$_d" == *"$_q"* ]] && { cd "$_d"; return; }
    done
    print -u2 "j: no match for '$_q'"
    return 1
}

# Register one shell function per configured jump command name.
local _finsh_jcmd
for _finsh_jcmd in "${_FINSH_JUMP_CMDS[@]}"; do
    functions[$_finsh_jcmd]='_finsh_jump "$@"'
done
unset _finsh_jcmd

zle -N _finsh_complete
bindkey '^I'   _finsh_complete   # Tab
bindkey '^[[Z' complete-word       # Shift+Tab — keep native completion
bindkey '^[[C' _finsh_autosuggest_accept   # Right arrow (most terminals)
bindkey '^[OC' _finsh_autosuggest_accept   # Right arrow (some terminals)
bindkey '^F'   _finsh_autosuggest_accept   # Ctrl+F (emacs forward-char, semantically equivalent)
