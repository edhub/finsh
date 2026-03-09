# AGENTS.md — finsh

## Project Overview

A zsh ZLE widget implementing Fish shell-style multi-level fuzzy completion, bypassing zsh's native prefix filtering.

> Architecture & implementation details: [DESIGN.md](DESIGN.md) · Installation & usage: [README.md](README.md)

---

## File Structure

```
finsh/
├── finsh.zsh             # Single implementation file
├── README.md             # Installation, keybindings, completion behaviour
├── DESIGN.md             # Architecture, implementation details, bug history
└── AGENTS.md             # This file
```

Production install path: `~/.zsh/plugins/finsh.zsh`  
Run tests: `zsh tests/test-help-parser.zsh`

---

## Constraints (read before modifying)

Every rule below corresponds to a bug history entry in [DESIGN.md § Bug History](DESIGN.md#bug-history).

### compadd hook → [DESIGN.md § compadd Hook and zle -C](DESIGN.md#compadd-hook-and-zle--c)

- Use `zle -C`, not `zle complete-word` directly — the C layer bypasses the function-level hook
- `_FINSH_POOL` must be `typeset -ga`; `_finsh_capture` must be defined at file top level
- Do **not** call `builtin compadd` — triggers "do you wish to see all N possibilities?"
- Combined flags (e.g. `-qS`): detect arg-taking flag chars with a regex and set `skip_next=1`; otherwise the suffix value (e.g. `=`) enters the candidate pool (Bug 8)

### Path completion → [DESIGN.md § Path Completion](DESIGN.md#path-completion)

- `~` does not expand in double quotes — use `${dir/#\~/$HOME}` (Bug 1)
- Glob qualifiers must include `D` (`*(.DN)`, `*(/DN)`) to match dotfiles (Bug 3)
- Root dir (`xbase=""`): glob as `/*(.DN)` etc. to avoid `//` double slashes (Bug 2)
- Filenames with spaces: `_FINSH_CANDS` stores `${(@q)names}` (shell-quoted for LBUFFER insertion); `_FINSH_SHOW_POOL` stores raw names (for re-filtering); `_FINSH_CANDS_PATH=1` marks path mode; display uses `${(Q)cand}`; pre-redraw refilter re-applies `(q)` when `_FINSH_CANDS_PATH=1` (Bug 22)

### Cycle state → [DESIGN.md § Cycle Mode](DESIGN.md#cycle-mode)

- Cycle condition must verify `LBUFFER == _FINSH_PFX + _FINSH_CANDS[_FINSH_IDX]`; without this, stale state is reused (Bug 9)

### Silent exit vs fallback → [DESIGN.md § Fallback Strategy](DESIGN.md#fallback-strategy)

- Registered fn exists but pool empty → fall back to `--help` first; exit silently only if help also yields nothing
- No registered fn and help yields nothing → `zle complete-word`
- `_arguments`-based fns (e.g. `_hx`) bypass the compadd hook via the `comparguments` C builtin; the `--help` fallback handles this (Bug 15)

### man page parsing → [DESIGN.md § Man Page Parsing](DESIGN.md#man-page-parsing-_finsh_parse_man)

- Final fallback; retrieves text via `man -P cat $cmd | col -bx`; cached under `"man:$cmd"` in `_FINSH_HELP_CACHE`
- `subcmds` state: name must be followed by `" ["` or end-of-line — prevents prose lines from entering the pool
- tmux: commands are in sub-sections, not a top-level `COMMANDS` section — man parsing doesn't work; use `tmux list-commands` instead

### opts-only tool routing → [DESIGN.md § Opts-Only Tool Routing](DESIGN.md#opts-only-tool-routing)

- Subcmds empty but opts non-empty: route to opts pool even if word doesn't start with `-` (Bug 16)
- Prepend `"--"` to word before filtering (`"bu"` → `"--bu"` → matches `--build`); `_FINSH_PFX` is unchanged

### Mid-line completion → `_FINSH_RBUF`

- No early-exit for `CURSOR != ${#BUFFER}`; cursor can be anywhere
- Every fill site must set **both** `LBUFFER` and `RBUFFER="$_FINSH_RBUF"`

### `zle -M` message starting with `-`

- `zle -M "msg"` with a message starting with `-` causes `bad option` — always write `zle -M -- "msg"` (Bug 17)

### History autosuggestion → [DESIGN.md § History Autosuggestion](DESIGN.md#history-autosuggestion)

- Wrap `accept-line`, not `zle-line-finish` — the latter fires too late (Bug 14)
- Set `_FINSH_SUGGESTION_NEEDLE="$LBUFFER"` (not `""`) after clearing, to prevent pre-redraw from re-searching (Bug 14)
- Use `zle -A accept-line _finsh_orig_accept_line` **before** defining the wrapper, then call `zle _finsh_orig_accept_line` (not `zle .accept-line`); `.accept-line` hard-codes the built-in and skips every other plugin's wrapper, breaking the chain when load order varies

### `j` directory history completion

- Candidate format: `"component → /full/path"` — `→` avoids glob expansion when the candidate sits in LBUFFER (not `[`/`]`)
- Pool-building variables (`_jparts`, `_ji`, `_jpath`) must be declared **outside** the outer loop (Bug 12)
- `_finsh_jump`: search for `→` at **any** argument position (not hardcoded `$# == 3`); join all args after `→` with spaces to reconstruct paths containing spaces

### Syntax pitfalls

- First word of a string: `${${(Az)prefix}[1]}` — **not** `${(z)prefix}[1]` (yields first character, Bug 6)
- History keys in order: `${(Onk)history}` — **not** `"${(@On)${(k)history}}"` (single-element, Bug 13)
- `local`/`typeset` inside a loop body prints its initialisation value on every iteration — declare outside the loop (Bug 12)
- `${(b)str}` escapes glob metacharacters only — ERE-only chars (`.`, `+`, `(`, `)`, `{`, `}`, `|`, `^`, `$`) are not escaped; use `_finsh_re_escape` (result in `_FINSH_RE_ESCAPED`) for `=~` patterns with dynamic content
- `}` in `${var//pat/rep}` replacement closes the outer expansion — use `\}` for a literal `}`: `"${s//\}/\\\}}"` (`\\\}` = one `\\` + `\}`)
- Strip word from LBUFFER with `"${lbuf[1,-${#word}-1]}"` (index-based) — **not** `"${lbuf%${word}}"` (glob chars break it) and **not** `"${lbuf%${(b)word}}"` (`(b)` inserts a literal `\` which `%` treats as part of the pattern, not an escape, Bug 21)

### `_finsh_filter` → [DESIGN.md § Matching Priority](DESIGN.md#matching-priority)

- First-letter pre-filter must not be removed (Bug 10)
- Use `${(b)word}` to escape glob metacharacters in pattern matching inside the filter

---

## Prerequisites

```zsh
source ~/.zsh/plugins/finsh.zsh
```

The script handles `fpath` and `compinit` automatically. If ordering with other plugins requires manual initialisation:

```zsh
fpath=(/opt/homebrew/share/zsh/site-functions $fpath)
autoload -Uz compinit
compinit -d ~/.zcompdump
source ~/.zsh/plugins/finsh.zsh
```
