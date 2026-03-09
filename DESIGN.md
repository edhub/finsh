# finsh — Design Document

> Installation: [README.md](README.md) · Modification traps & syntax pitfalls: [AGENTS.md](AGENTS.md)

---

## Completion Flow

```
Tab
 │
 ├─ Show mode active (_FINSH_SHOW_MODE=1)
 │   → fill first candidate, enter cycle mode
 │
 ├─ Cycle mode (LASTWIDGET==_finsh_complete
 │              && LBUFFER==_FINSH_PFX+_FINSH_CANDS[_FINSH_IDX])
 │   → advance index (wraps around)
 │
 └─ New round: reset state → collect pool → filter → show or fill
      │
      ├─ cursor not at end of line → mid-line completion:
      │   strip leading non-space chars of RBUFFER (right part of current word)
      │   → save as _FINSH_RBUF; restore when filling a candidate
      │   (cursor at word boundary: _FINSH_RBUF = full RBUFFER; no stripping needed)
      │
      ├─ word contains /  → _finsh_try_path (glob + basename filter)
      │
      ├─ prefix is all-whitespace → command name completion
      │   pool = commands + public functions + aliases + builtins
      │
      └─ subcommand / option → _finsh_collect_subcmd_pool
           │
           ├─ cmd == "j" && _FINSH_DIR_HIST non-empty
           │   → pool = _FINSH_DIR_HIST (all path components); return early
           │
           ├─ _comps[$cmd] exists → zle -C + compadd hook (_finsh_capture)
           │   pool empty (_arguments bypasses hook) ↓
           ├─ $cmd --help → _finsh_parse_help (state machine)
           │   no results ↓
           └─ man $cmd → _finsh_parse_man
                no results:
                  _registered=1 → silent exit
                  _registered=0 → zle complete-word

After collecting pool:
  • Deduplicate → _finsh_filter (Pass 1 → 2c)
  • 0 results + word non-empty → silent exit
  • 1 result → fill directly (LBUFFER = prefix + candidate)
  • 2+ results → show mode: zle -M displays list; live re-filter on each keystroke
```

---

## Matching Priority

Pre-filter: pool narrowed to candidates whose first letter == `word[1]`.
Then in order; first hit wins:

| Pass | Strategy | Example |
|------|----------|---------|
| 1 | Exact prefix | `pi` → `pi-claude` |
| 2a | Substring | `pi-cl` → `pi-claude` |
| 2b | Head-anchored subsequence | `piclaud` → `pi-claude` |
| 2c | Pure subsequence | `pclaud` → `pi-claude` |

Results written to `_FINSH_FILTERED` (global, avoids subshell).
Glob metacharacters escaped with `${(b)word}` before matching.

---

## Path Completion

`word contains /` → `_finsh_try_path`:

```
dir  = word:h          base = word:t  (basename used for filtering)
xdir = dir with ~ expanded via ${dir/#\~/$HOME}   (~ doesn't expand in double quotes)
xbase = xdir with trailing / stripped             (avoids //Applications at root)
glob: "${xbase}"/*(.DN)  *(/DN)  *(@DN)           (D qualifier includes dotfiles)
filter names by base → 1 match: fill; many: show mode; 0 matches: zle complete-word
```

Special cases:
- `word` ends with `/` (base=""): fall back to `zle complete-word` (native handles it)
- Root dir (xbase=""): glob as `/*(.DN)` etc. (no prefix concat → no double slash)

---

## Cycle Mode

Cycle condition — all three must hold:
1. `LASTWIDGET == "_finsh_complete"`
2. `$#_FINSH_CANDS > 0`
3. `LBUFFER == "${_FINSH_PFX}${_FINSH_CANDS[$_FINSH_IDX]}"`

Condition 3 prevents stale state reuse after manual buffer edits (Bug 9).

---

## Subcommand / Option Completion

### compadd Hook and zle -C

Normal `zle complete-word` → C layer → `compadd` builtin directly (function override bypassed).
`zle -C` establishes a completion context where `function compadd() {...}` takes effect.

```zsh
zle -C _finsh_cap complete-word _finsh_capture
{ LBUFFER="$prefix"; RBUFFER=""; zle _finsh_cap 2>/dev/null } always {
    LBUFFER="$slbuf"; RBUFFER="$srbuf"
    zle -D _finsh_cap; unfunction compadd
}
```

`_finsh_capture` shadows `compadd` to collect candidates into `_FINSH_POOL`.
**Do not call `builtin compadd`**: writes to zsh's completion buffer → "do you wish to see all N?"
**Always return 0**: prevents completion functions from taking fallback branches and missing candidates.

### --help Parser (`_finsh_parse_help`)

Single-pass state machine. Initial state: `flat`.

Section header (line ≤40 chars, starts with a letter) switches state:
- `*commands*` / `*subcommands*:` → `subcmds`
- `*options*` / `*flags*:` → `opts`
- All-caps `USAGE:` / `ARGS:` etc. → `other` (skip)

The 40-char limit filters long description sentences (e.g. git's "These are common Git commands...") from being mistaken for headers.

Extraction per state:
- `subcmds`: 1–8 space indent + lowercase name; comma-separated aliases split; cobra `prog subcmd` format supported
- `opts`: `--flag` lines with or without `-x,` short prefix; `-[a-zA-Z0-9]+` matches multi-char short options (`-nv`, `-4`)
- `flat`: both subcommands (2–8 space indent + 2+ space gap after name) and `--flag` lines simultaneously

### Man Page Parsing (`_finsh_parse_man`)

Last resort for BSD/POSIX tools (ssh, cp, find) with no `--help`.
Called as: `man -P cat $cmd | col -bx`; result cached in `_FINSH_HELP_CACHE["man:$cmd"]`.

Section headers: all-uppercase, no colon, length ≤40 (e.g. `COMMANDS`, `OPTIONS`).

- `subcmds`: 3–12 space indent + lowercase-hyphen name + `" ["` or end-of-line (the `" ["` requirement filters prose lines like "target-session is tried as...")
- `opts`: `--flag` lines + single-dash `-x` / `-xy` (3–12 spaces + 1+ spaces)
- `other` (DESCRIPTION etc.): BSD inline options — `3–12 spaces + -x + 1+ spaces` (captures ssh/cp-style options embedded in DESCRIPTION)

Known limitation: tmux commands are spread across sub-sections (`CLIENTS AND SESSIONS` etc.) rather than a `COMMANDS` section → man parsing is ineffective; use `tmux list-commands` instead.

### Opts-Only Tool Routing

Tools with options but no subcommands (node, hx): when word doesn't start with `-`, prepend `--`:
`"bu"` → `"--bu"` → prefix-matches `--build-sea`. `_FINSH_PFX` unchanged; candidate replaces the original word.

### Fallback Strategy

| Situation | Behaviour |
|-----------|-----------|
| Registered completion fn exists, all paths empty | Silent exit |
| No registered fn, all paths empty | `zle complete-word` |

---

## History Autosuggestion

`zle-line-pre-redraw` → `_finsh_update_suggestion` on every keystroke.
`_finsh_search_history` iterates `${(Onk)history}` (most-recent first) for first entry starting with `LBUFFER`.
Result shown via `POSTDISPLAY` + `region_highlight` (`fg=8`, `memo=finsh-sug`).

`accept-line` is wrapped (`_finsh_accept_line`): clears suggestion and sets `_FINSH_SUGGESTION_NEEDLE="$LBUFFER"`.
Setting needle to `$LBUFFER` (not `""`) prevents pre-redraw from re-searching and restoring the cleared suggestion.

---

## Bug History

| # | Symptom | Key fix |
|---|---------|---------|
| 1 | `~` path glob fails | `${dir/#\~/$HOME}` — `~` doesn't expand in double quotes |
| 2 | Root: `//Applications` | `xbase="${xdir%/}"`, special-case empty xbase |
| 3 | Dotfiles hidden in path completion | Add `D` glob qualifier: `*(.DN)` |
| 4 | `cargo bu` → local file | Parse `--help` when no registered completion fn |
| 5 | `cargo build --rel` fails | Route to opts pool when word starts with `-` |
| 6 | `${(z)prefix}[1]` → first char | Use `${${(Az)prefix}[1]}` |
| 7 | `just <tab>` inserts `=` (surface) | `_registered=1` + empty pool → silent exit |
| 8 | `just <tab>` inserts `=` (root cause) | Combined flag `-qS`: detect arg-taking chars → `skip_next=1` |
| 9 | Cycle reuses stale state | Add `LBUFFER == _FINSH_PFX + _FINSH_CANDS[_FINSH_IDX]` to cycle condition |
| 10 | `picli` matches thousands of candidates | First-letter pre-filter before all filter passes |
| 11 | No match dumps entire pool | word non-empty + no match → silent exit |
| 12 | `npm in` prints `_part=''` garbage | `local` outside loop body; comma list parsing |
| 13 | History suggestion always empty | `${(Onk)history}` without outer quotes |
| 14 | Gray suggestion printed to terminal after Enter | Wrap `accept-line`; set needle to `$LBUFFER` not `""` |
| 15 | `hx <Tab>` → nothing | `_arguments` bypasses compadd hook → fall through to `--help` |
| 16 | `node bu` → nothing | Opts-only routing: prepend `--` to word |
| 17 | 2nd Tab: `bad option: -b` | `zle -M -- "msg"` when message may start with `-` |
| 18 | `cargo bu` shows `but` | Strip description before comma-splitting aliases |
| 19 | `wget --no` misses options | Short option regex: `-[a-zA-Z0-9]+` not `-[a-zA-Z]` |
| 20 | `wget -hel` → nothing | `_arguments` side-effect filenames in pool mask `--help` path |
