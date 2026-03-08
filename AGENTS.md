# AGENTS.md — finsh

## Project Overview

A zsh ZLE widget that completely bypasses zsh's native prefix filtering, implementing Fish shell-style multi-level fuzzy completion.

> Architecture and implementation details: [DESIGN.md](DESIGN.md).  
> Installation and usage: [README.md](README.md).

---

## File Structure

```
finsh/
├── finsh.zsh             # Single implementation file
├── README.md             # Installation, keybindings, completion behaviour
├── DESIGN.md             # Design document (architecture, implementation details, bug history)
└── AGENTS.md             # This file (AI agent context)
```

Production install path: `~/.zsh/plugins/finsh.zsh`

---

## Read Before Modifying

Every constraint below has a corresponding bug history entry in [DESIGN.md § Bug History](DESIGN.md#bug-history).

### compadd hook → [DESIGN.md § compadd Hook and zle -C](DESIGN.md#compadd-hook-and-zle--c)

- Must use `zle -C`; calling `zle complete-word` directly goes through the C layer and the hook is never invoked
- `_FINSH_POOL` must be `typeset -ga`; `_finsh_capture` must be defined at the top level of the file
- Do **not** call `builtin compadd`, or zsh will trigger "do you wish to see all N possibilities?"
- Combined flags (e.g. `-qS`) must be checked with a regex for flag characters that take an argument, then `skip_next=1`; otherwise the suffix value (e.g. `=`) is treated as a candidate (Bug 8)

### Path completion → [DESIGN.md § Path Completion](DESIGN.md#path-completion)

- `~` does not expand inside double quotes; use `${dir/#\~/$HOME}` to substitute (Bug 1)
- glob must include the `D` qualifier (`*(.DN)` / `*(/DN)`) to match dotfiles (Bug 3)
- Root directory `xbase=""` requires special handling to avoid `//Applications` double slashes (Bug 2)

### Cycle state → [DESIGN.md § Cycle Mode](DESIGN.md#cycle-mode)

- The cycle condition must verify `LBUFFER == _FINSH_PFX + _FINSH_CANDS[_FINSH_IDX]`; without this check, stale state is reused (Bug 9)

### Silent exit vs fallback → [DESIGN.md § Fallback Strategy](DESIGN.md#fallback-strategy)

- Registered completion function exists but pool is empty → **fall back to `--help` path first**; only exit silently if help also yields nothing
- No registered function and help yields nothing → fallback `zle complete-word` (Bug 7 / Bug 15)
- `_arguments`-based completion functions (e.g. `_hx`) use the `comparguments` C builtin, which **bypasses** the function-level compadd hook, leaving the pool permanently empty; the fallback path handles this (Bug 15)

### man page parsing → [DESIGN.md § Man Page Parsing](DESIGN.md#man-page-parsing-_finsh_parse_man)

- `_finsh_parse_man` is the final fallback when `--help` yields no results; retrieves text via `man -P cat $cmd | col -bx`
- Section headers: all-uppercase without a colon (`COMMANDS`, `OPTIONS`); line length ≤ 40 chars
- `other` state (includes `DESCRIPTION`) detects BSD inline options: `3–12 spaces + -x + 1+ spaces` (ssh/cp style)
- `subcmds` state requires the name to be followed by `" ["` or end-of-line, to filter out prose lines like `"target-session is tried"`
- Cache key prefixed with `"man:"`, reusing `_FINSH_HELP_CACHE` (only one fork per session)
- Known limitation: tmux commands are spread across sub-sections (`CLIENTS AND SESSIONS`, etc.) rather than a `COMMANDS` section → man parsing does not work for tmux; use `tmux list-commands` instead

### opts-only tool routing → [DESIGN.md § Opts-Only Tool Routing](DESIGN.md#opts-only-tool-routing)

- When subcmds is empty but opts is non-empty, route to the opts pool even if word does not start with `-` (Bug 16)
- Prepend `"--"` to `word`: `"bu"` → `"--bu"` → prefix-matches `--build-sea`
- `_FINSH_PFX` is unchanged; the candidate replaces the original word directly

### Mid-line completion → `_FINSH_RBUF`

- Cursor can be anywhere in the line; no early-exit for `CURSOR != ${#BUFFER}`
- At the start of each new completion round, compute `_rword` = leading non-space chars of `RBUFFER` (the right part of the word under the cursor)
- `_FINSH_RBUF = RBUFFER[${#_rword}+1,-1]` — the text that should follow the completed word
- Every candidate fill site must set **both** `LBUFFER` and `RBUFFER="$_FINSH_RBUF"` (show-mode fill, cycle fill, single-candidate fill, path single-candidate fill)
- When cursor is at a word boundary (RBUFFER starts with space or is empty): `_rword=""` and `_FINSH_RBUF = RBUFFER` — no stripping, most common case

### `zle -M` message starting with `-` → [DESIGN.md § Bug History](DESIGN.md#bug-history)

- When the message passed to `zle -M "msg"` starts with `-`, zle parses it as its own option and reports `bad option` (Bug 17)
- Rule: **whenever the content of a `zle -M` message may start with `-`, always write `zle -M -- "msg"`**

### History autosuggestion → [DESIGN.md § History Autosuggestion](DESIGN.md#history-autosuggestion)

- Must wrap `accept-line`; `zle-line-finish` fires too late (Bug 14)
- After clearing the suggestion, set `_FINSH_SUGGESTION_NEEDLE` to `"$LBUFFER"` (not `""`), to prevent `pre-redraw` from re-searching history (Bug 14)

### Syntax pitfalls

- `${${(Az)prefix}[1]}` to get the first word; do **not** write `${(z)prefix}[1]` (that yields the first character, Bug 6)
- `${(Onk)history}` without outer quotes; do **not** write `"${(@On)${(k)history}}"` (treats all keys as a single element, Bug 13)
- `local` declarations must be placed **outside** loop bodies; `typeset` inside a loop body prints its initialisation side-effect to the terminal on every iteration (Bug 12)

### `_finsh_filter` → [DESIGN.md § Matching Priority](DESIGN.md#matching-priority)

- The first-letter pre-filter must not be removed (Bug 10)
- Use `${(b)word}` to escape glob metacharacters in pattern matching

---

## Prerequisites

```zsh
source ~/.zsh/plugins/finsh.zsh
```

The script handles `fpath` and `compinit` automatically. If you need to initialise manually before sourcing finsh (e.g. due to ordering requirements with other completion plugins), you may still write:

```zsh
fpath=(/opt/homebrew/share/zsh/site-functions $fpath)
autoload -Uz compinit
compinit -d ~/.zcompdump
source ~/.zsh/plugins/finsh.zsh
```
