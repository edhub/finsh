# Bug History

> Back to [DESIGN.md](../DESIGN.md)

> 中文文档：[bugs.zh.md](bugs.zh.md)

---

## Path Completion

### Bug 1 — `~` path glob failure (`cd ~/dev/fzf<tab>`)

**Cause**: `~` does not expand inside double quotes; `"${~dir}"` syntax doesn't work in this context.  
**Fix**: Use `${dir/#\~/$HOME}` to manually replace the prefix.

### Bug 2 — Double slash at root (`cd /Use<tab>` → `//Users`)

**Cause**: When `dir="/"`, `xbase="/"` produces `"/"/*` = `//Applications` etc.  
**Fix**: Strip trailing slash with `xbase="${xdir%/}"` and handle `xbase=""` separately using `/*(.DN)` glob.

### Bug 3 — Dotfiles not appearing (`vi ~/.zsh<tab>` → `AndroidStudioProjects`)

**Cause**: Glob `*` does not match `.`-prefixed files by default; filter hits nothing, `show=pool`, first alphabetically sorted candidate is a non-dotfile.  
**Fix**: Add `D` qualifier to glob: `*(.DN)` / `*(/DN)`.

---

## Help Parsing

### Bug 4 — `cargo bu<tab>` completes to a local file

**Cause**: `_comps[cargo]` is empty, zle-C path skipped, help parsing also skipped; empty pool falls back to `zle complete-word` → `_default` → file completion.  
**Fix**: When no registered completion function exists, parse `cargo --help`; if word doesn't start with `-`, use 4-space-indented subcommand lines as pool.

### Bug 5 — `cargo build --rel<tab>` fails to complete

**Cause**: `--rel` starts with `-` but pool came from `_FINSH_PARSE_SUBCMDS` (empty).  
**Fix**: When word starts with `-`, use option lines (`--flag` format) as pool.

### Bug 12 — `npm in<tab>` outputs `_part=''` garbage + misses `install`

**Cause (two issues)**:
1. `npm --help` lists subcommands **comma-separated on one line** (`    access, adduser, ..., install, ...`); old logic only grabbed the first word per line, missing `install` and others in the middle.
2. During the fix, `local _part` was declared inside the `while` loop body; in a zle widget context, `typeset` re-executes on every iteration, printing `_part=''` to the terminal as a side effect.

**Fix**:
1. When a subcommand line contains commas, split by `,`, strip whitespace, validate each word against `'^[a-z][-a-z0-9]*$'`, and add all matches to pool.
2. Move `local _part` **outside** the `while` loop, combined with the `_help_line` declaration so `local` runs only once.

---

## Language / Syntax Traps

### Bug 6 — `${(z)prefix}[1]` returns first character instead of first word

**Cause**: `${(z)prefix}` returns an array, but subscript outside `${}` indexes into the string's characters.  
**Fix**: Change to `${${(Az)prefix}[1]}`; `(A)` forces the result to an array before taking index `[1]`.

### Bug 13 — History suggestion always empty

**Cause**: `"${(@On)${(k)history}}"` with outer quotes makes `@` treat `${(k)history}`'s scalar expansion `"3 2 1"` as a **single element**, resulting in `nums=("3 2 1")`; using it to look up `$history` finds nothing.  
**Fix**: Change to `${(Onk)history}` — `k` acts directly as an expansion flag; without outer quotes, word-splitting correctly produces separate elements:

```zsh
nums=( ${(Onk)history} )   # ✓ yields ("3" "2" "1")
```

---

## compadd Hook Parsing

### Bug 8 — `just <tab>` with no justfile completes to `=` (root cause)

**Cause**: `_describe` passes `compadd` the combined flag `-qS` (not `-q -S`). The hook's `-*` branch ignores `-qS`, the next argument `=` (suffix value) is not skipped, and gets added to pool as a candidate — pool becomes `("=")` → sole candidate is directly completed.  
**Fix**: In the `-*` branch, detect whether the combined flag contains any argument-taking characters (`[PSpsWdJVXxrRMFtoEIi]`); if so, set `skip_next=1`.

---

## Cycle State

### Bug 7 — `just <tab>` with no justfile completes to `=` (surface symptom)

**Cause**: `_comps[just]=_just` so zle-C capture runs; pool is empty; fallback `zle complete-word` triggers `_just` again in a real completion context, inserting `=` as a suffix into the buffer.  
**Fix**: Introduce `_registered` flag; when a registered completion function exists but pool is empty, **silently exit** instead of falling back.

### Bug 9 — Cycle mode reuses stale state

**Cause**: Cycle check only examined `$LASTWIDGET` and `$#_FINSH_CANDS`, without verifying buffer position. After the old bug left `_FINSH_CANDS=("=")`, the next Tab entered the cycle loop and reproduced the issue.  
**Fix**: Add `[[ "$LBUFFER" == "${_FINSH_PFX}${_FINSH_CANDS[$_FINSH_IDX]}" ]]` to the cycle condition; buffer mismatch is treated as a new completion round.

---

## Overly Broad Matching

### Bug 10 — Typing `picli` shows large numbers of unrelated candidates

**Cause**: Pass 2c (pure subsequence) generates `*p*i*c*l*i*`, which matches any string containing those five letters in order across thousands of commands in the pool.  
**Fix**: Add a first-letter pre-filter before all passes in `_finsh_filter`, narrowing the pool to candidates whose first letter matches `word[1]`: `pool=( ${(M)pool:#${(b)word[1]}*} )`.

### Bug 11 — No match dumps the entire pool

**Cause**: When `_FINSH_FILTERED` is empty, `show` falls back to the full pool, displaying thousands of candidates.  
**Fix**: In the main widget, when `word` is non-empty but there are no matches, return immediately; only show the full pool when `word` is empty.

```zsh
if (( $#_FINSH_FILTERED )); then
    show=("${_FINSH_FILTERED[@]}")
elif [[ -z "$word" ]]; then
    show=("${pool[@]}")
else
    return   # input present but no matches — exit silently
fi
```

---

## History Autosuggestion

### Bug 14 — Gray suggestion remains in terminal output after Enter

**Symptom**: History contains `ls tools`; user types `ls` and presses Enter; terminal output shows `ls tools` but only `ls` was executed.

**Root cause (two layers)**:
1. `zle-line-finish` fires too late — ZLE has already completed final rendering and printed to the terminal; clearing `POSTDISPLAY` at that point has no effect.
2. After wrapping `accept-line` to clear the suggestion, resetting `_FINSH_SUGGESTION_NEEDLE` to `""` causes the subsequent `zle-line-pre-redraw` to see `LBUFFER != needle`, re-search history, and write the suggestion back to `POSTDISPLAY`, undoing the clear.

**Fix**: Wrap `accept-line`; after clearing the suggestion, set `_FINSH_SUGGESTION_NEEDLE` to the **current `$LBUFFER`**:

```zsh
_finsh_accept_line() {
    POSTDISPLAY=""
    region_highlight=( ${region_highlight:#*memo=finsh-sug} )
    _FINSH_SUGGESTION=""
    _FINSH_SUGGESTION_NEEDLE="$LBUFFER"   # ← lock needle to block pre-redraw from re-searching
    zle .accept-line
}
zle -N accept-line _finsh_accept_line
```

---

## `_arguments` Bypassing compadd Hook / opts-only Tools

### Bug 15 — `hx <Tab>` produces no completion (`_arguments` bypasses function-level compadd)

**Symptom**: `hx` has a registered completion function `_hx`, but `hx <Tab>` shows nothing.

**Root cause**: `_hx` uses `_arguments -C`; its underlying `comparguments` is a C builtin that **completely bypasses** the function-level `compadd` hook. `_FINSH_POOL` remains empty; `_registered=1` and pool empty → silently exit.

```
zle -C → _finsh_capture → function compadd() { ... } → _main_complete
                                                          → _hx
                                                          → _arguments -C
                                                          → comparguments (C builtin)
                                                             ← does not go through function compadd ✗
```

**Fix**: Move `--help` parsing out of the `else` branch and into `if (( $#pool == 0 )) && ...`, so that a registered function with an empty hook also takes the `--help` path:

```zsh
if [[ -n "${_comps[$_cmd]-}" ]]; then
    _registered=1
    # ... zle -C capture ...
    pool=( "${_FINSH_POOL[@]}" )
fi
# compadd capture empty OR no registered function → fall back to --help
if (( $#pool == 0 )) && [[ -n "$_cmd" ]]; then
    # ... --help parsing ...
fi
```

### Bug 16 — `node bu<Tab>` produces no completion (opts-only tool routing error)

**Symptom**: `node --help` lists 181 options, but `node bu<Tab>` completes nothing.

**Root cause**: `word = "bu"` doesn't start with `-` → routes to `_FINSH_PARSE_SUBCMDS` pool → node has no subcommands → pool empty → fallback file completion → no match.

**Fix**: When subcmds is empty but opts is non-empty, include opts in pool and prepend `--` to `word`:
- `"bu"` → `"--bu"` → prefix-matches `--build-sea`, `--build-snapshot`, `--build-snapshot-config`
- `_FINSH_PFX` remains `"node "`; candidate directly replaces the original `"bu"`, making LBUFFER `"node --build-sea"`

### Bug 17 — `node -b<Tab><Tab>` second Tab errors with `zle:24: bad option: -b`

**Symptom**: First Tab works correctly (LBUFFER → `node --build-sea`); second Tab errors with `_finsh_show_candidates:zle:24: bad option: -b`.

**Root cause**: `_finsh_show_candidates` ends with `zle -M "${(j:\n:)out}"`. After formatting, the candidate list's first line looks like `"--build-sea  [--build-snapshot]  ..."`, starting with `-`. zsh's option parser treats this string as options, finding `-b` to be a "bad option".

```zsh
# Broken: zle parses "--build-sea ..." as its own options
zle -M "--build-sea  [--build-snapshot]  ..."
#        ↑ starts with -, parsed as option

# Fix: use -- to stop option parsing
zle -M -- "--build-sea  [--build-snapshot]  ..."
#     ↑↑ everything after -- is treated as positional argument
```

**Fix**: Change `zle -M` to `zle -M -- "..."`. **Rule: whenever `zle -M` message content may start with `-`, always add `--`.**

---

### Bug 18 — `cargo bu<Tab>` candidate list includes `but` (comma in description mistaken for alias separator)

**Symptom**: `cargo bu<Tab>` shows `[build]  but`; `but` is spurious noise.

**Root cause**: `cargo --help` contains a line like:

```
    check, c    Analyze the current package and report errors, but don't build object files
```

The old logic did `${(s:,:)_line}` on the entire `_line`. One of the resulting parts is ` but don`, which after stripping whitespace becomes `but`, matching `^[a-z][-a-z0-9]*$` and getting added to subcmds.

**Fix**: Before splitting on commas, strip the description part (aliases and description are always separated by 2+ spaces):

```zsh
local _trimmed="${_line##[[:space:]]#}"
local _aliases_part="${_trimmed%%  *}"   # keep only the part before the first 2-space gap
for _part in "${(s:,:)_aliases_part[@]}"; do ...
```

Applied to both the `subcmds` and `flat` branches.

---

### Bug 19 — `wget --no<Tab>` misses `--no-verbose` and other options (multi-character short options don't match)

**Symptom**: `wget --no<Tab>` is missing `--no-verbose`, `--no-clobber`, `--inet4-only`, `--inet6-only`, and 3 others (7 options total).

**Root cause**: The options regex short-option prefix was `(-[a-zA-Z],?[[:space:]]+)?`, allowing only **single-letter** short options (e.g. `-V,`). wget has multi-character / numeric short options like `-nv,`, `-nc,`, `-4,`, `-6,`; those lines fail to match and the corresponding `--long` option is also lost.

**Fix**: Change `-[a-zA-Z]` to `-[a-zA-Z0-9]+` to allow any-length short option identifiers:

```zsh
# Before
'^[[:space:]]+((-[a-zA-Z],?[[:space:]]+)?)(--([a-zA-Z][a-zA-Z0-9-]*))'
# After
'^[[:space:]]+((-[a-zA-Z0-9]+,?[[:space:]]+)?)(--([a-zA-Z][a-zA-Z0-9-]*))'
```

After the fix, all 153 wget options are covered; cargo/git are unaffected.

---

### Bug 20 — `wget -hel<Tab>` silently produces no completion (`_arguments` side-effect pollutes pool)

**Symptom**: `wget -hel<Tab>` completes nothing; expected result is `--help`.

**Root cause**: `_wget` uses `_arguments` with `'*:URL:_urls'`. In the zle -C completion context, `_arguments` invokes `_urls → _files → compadd` for the positional argument, and our hook captures local filenames (`AGENTS.md`, `README.md`, etc.). At this point:

1. `$#pool != 0` (pool has filenames) → original condition `$#pool == 0` is false → `--help` path is skipped
2. `_finsh_filter "-hel" ["AGENTS.md" "README.md" ...]` → first-letter pre-filter `-*`: no files start with `-` → pool cleared → silently exit

**Fix**: Add a third condition for entering the `--help` path: `word` starts with `-` but pool contains no `-*` candidates (i.e. pool is entirely non-option content). In that case, discard the pool and take the `--help` path:

```zsh
if [[ -n "$_cmd" ]] && {
    (( $#pool == 0 )) ||
    { [[ "$word" == -* ]] && (( ${#${(M)pool:#-*}} == 0 )) }
}; then
    pool=()   # discard irrelevant candidates
```
