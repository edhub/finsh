# Subcommand / Option Completion and the compadd Hook

> Back to [DESIGN.md](../DESIGN.md)

> 中文文档：[subcommand.zh.md](subcommand.zh.md)

---

## Subcommand / Option Completion

### With a registered completion function (`$_comps[$cmd]` non-empty)

Takes the `zle -C` capture path; see the next section. Sets `_ble_registered=1`.

**Important**: some completion functions (e.g. `_hx`) use `_arguments`, whose underlying `comparguments` is a C builtin that **completely bypasses** the function-level `compadd` hook, causing `_FINSH_POOL` to always remain empty. In this case the plugin automatically falls back to the `--help` parsing path instead of silently exiting.

### `--help` parsing (`_finsh_parse_help` state machine)

`_finsh_parse_help` is a single-pass state machine that identifies section headers first, then extracts content according to the current state.

```
Initial state: flat (heuristic, for tools without sections, e.g. git)

Section header detection: line length ≤ 40 chars (filters long description sentences)
  and starts with a letter:
  *commands* / *subcommands*:  → subcmds state (extract indented subcommands)
  *options*  / *flags*:        → opts state   (extract --flags)
  ALL-CAPS header (USAGE: ARGS:) → other state (skip entire section)
```

The 40-character limit is the key guard that distinguishes section headers (e.g. `Commands:`) from normal description sentences (e.g. git's `These are common Git commands used in various situations:`).

**Extraction rules per state**:

| State | Subcommand extraction | Option extraction |
|-------|-----------------------|-------------------|
| `subcmds` | 1–8 space indent + lowercase first word; comma-separated lists are split | — |
| `opts` | — | `--flag` lines (with or without `-x,` short-form prefix) |
| `other` | — | — |
| `flat` | 2–8 space indent + name followed by **2+** spaces (filters `  hx [FLAGS]...`-style USAGE lines); comma lists | `--flag` lines |

The 2+ space gap requirement in `flat` state filters two categories of false positives:
- `    hx [FLAGS]...`: only 1 space after `hx` → no match
- 35+ space-aligned continuation lines (e.g. hx's `or 'all'...`): indent exceeds 8 → no match

### Routing for opts-only tools (no subcommands, only options)

For tools like `node` or `hx` that have only options and no subcommands, the word should still route to the options pool even when it doesn't start with `-`:

```zsh
if [[ "$word" == -* ]]; then
    pool=( "${_FINSH_PARSE_OPTS[@]}" )
elif (( $#_FINSH_PARSE_SUBCMDS )); then
    pool=( "${_FINSH_PARSE_SUBCMDS[@]}" )
elif (( $#_FINSH_PARSE_OPTS )); then
    # No subcommands but options exist: include opts in pool.
    # Prepend "--" to non-empty word so "bu" prefix-matches "--build-sea".
    pool=( "${_FINSH_PARSE_OPTS[@]}" )
    [[ -n "$word" ]] && word="--${word}"
fi
```

**Effect**: `node bu<Tab>` → `word` becomes `"--bu"` → prefix-matches `--build-sea`, `--build-snapshot`, etc. `_FINSH_PFX` remains the original `prefix` (`"node "`), and the candidate directly replaces the original word (`"bu"` becomes `"--build-sea"`).

### Fallback strategy when pool is empty

| Situation | Behavior |
|-----------|----------|
| Registered completion function exists, capture yields nothing, `--help` also yields nothing | **Silently exit** (avoids `_just` producing `=` when no justfile exists) |
| No registered completion function, help also yields nothing | **Fallback** to `zle complete-word` (typically file completion) |

> ⚠️ **Modification notes**
> - `_FINSH_HELP_CACHE` is `typeset -gA`; key = space-joined command words; only one fork per session. After changing help parsing logic, ensure cache key consistency
> - **`_ble_registered` flag**: set to 1 when `_comps[$cmd]` is non-empty. When pool is empty: `_ble_registered=1` → silently exit; `=0` → fallback `zle complete-word`. This prevents `_just` and similar from producing `=` noise on a second trigger
> - `local` declarations must be placed **outside** `while`/`for` loop bodies; in a zle widget context, `typeset` inside a loop body outputs its initialization side-effect (e.g. `var=''`) to the terminal on every iteration

---

## The `compadd` Hook and `zle -C`

### Why `zle -C` is required

```
Normal widget → zle complete-word → C layer calls compadd directly  ← hook ineffective ✗

Normal widget → zle -C _cap complete-word _capture
                          → _main_complete → _git / _docker …
                                               → compadd()   ← hook works ✓
```

### Call flow

```zsh
# 1. Register a temporary completion widget
zle -C _finsh_cap complete-word _finsh_capture

# 2. Save/set LBUFFER so the completion system generates full candidates in an "empty word" context
{
    LBUFFER="$prefix"   # strip the current word
    RBUFFER=""; CURSOR=${#LBUFFER}
    zle _finsh_cap 2>/dev/null
} always {
    LBUFFER="$slbuf"; RBUFFER="$srbuf"   # restore regardless of success/failure
    zle -D _finsh_cap 2>/dev/null
    unfunction compadd 2>/dev/null
}

pool=( "${_FINSH_POOL[@]}" )
```

### `_finsh_capture` implementation notes

- Define `function compadd()` inside the completion context to shadow the builtin
- **Do not call `builtin compadd`**: candidates are written only to `_FINSH_POOL`, not to zsh's completion buffer — otherwise zsh triggers "do you wish to see all N possibilities?" on exit
- Always `return 0` to prevent completion functions from taking a fallback branch and missing candidates
- `_FINSH_POOL` must be `typeset -ga` (global); completion context cannot access `local` variables from the outer widget
- `_finsh_capture` must be defined at **file top level** (not inside a function) for `zle -C` to find it

### `compadd` argument parsing

| Argument | Handling |
|----------|----------|
| `-O`/`-D`/`-A` | Internal array operations; `return 0` skips the entire call |
| `-a name` | Expand array `"${(@P)name}"` and add to pool |
| `-k name` | Expand hash keys `"${(kP)name}"` and add to pool |
| `-[PSpsWdJVXxrRMFtoEIi]` (standalone) | Flag with argument; set `skip_next=1` to skip the next argument |
| `-*` (combined flags, e.g. `-qS`, `-ld`) | If contains any argument-taking characters, set `skip_next=1`; otherwise ignore |
| `--` | Everything after is treated as candidate words |
| Other non-`-` prefixed | Candidate word; add to pool |

> ⚠️ **Modification notes**
> - `-[ODA]` skips the entire call; `-a`/`-k` expand array/hash keys; standalone argument-taking flags use exact matching; **combined flags use regex detection for argument-taking characters** (`_describe` passes `-qS` not `-q -S` — without detection the suffix value like `=` gets treated as a candidate)
> - `_FINSH_POOL` must be `typeset -ga`; `_finsh_capture` must be defined at file top level
