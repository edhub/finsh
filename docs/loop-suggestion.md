# Two-Phase Completion and History Autosuggestion

> Back to [DESIGN.md](../DESIGN.md)

> 中文文档：[loop-suggestion.zh.md](loop-suggestion.zh.md)

---

## Two-Phase Completion

Completion state is maintained across widget calls by four global variables:

```zsh
typeset -ga _FINSH_CANDS   # candidate list
typeset -gi _FINSH_IDX=0   # current index (1-based)
typeset -g  _FINSH_PFX=""  # candidate prefix (the invariant part of LBUFFER)
typeset -g  _FINSH_WORD="" # the original typed word (used as fzf popup query)
```

### 1st Tab — Inline Fill

`_finsh_complete` collects and filters candidates, writes the first candidate into `LBUFFER`,
and uses `zle -M` to display the candidate list below the prompt (`[current]` marked with brackets):

```
[list]  link  linkage  livecheck
```

`_FINSH_WORD` (the original typed word, e.g. `li`) is saved for use as the fzf initial query on the 2nd Tab.

### 2nd Tab — fzf Popup

The 2nd Tab is triggered only when all three conditions hold:

```zsh
[[ "$LASTWIDGET" == "_finsh_complete" ]]                              # previous widget was this widget
&& (( $#_FINSH_CANDS ))                                               # candidates exist
&& [[ "$LBUFFER" == "${_FINSH_PFX}${_FINSH_CANDS[$_FINSH_IDX]}" ]]  # buffer matches last fill
```

The third condition is critical — it prevents stale `_FINSH_CANDS` from being reused after the user manually edits the buffer (Bug 9).

When triggered:

1. Snapshot `_FINSH_PFX` / `_FINSH_CANDS` / `_FINSH_WORD` to local variables
2. Immediately zero out global state and clear the `zle -M` message to avoid state pollution after fzf returns
3. Launch fzf (`--height=~10` inline mode, `--query="$typed"` pre-filled with original typed word)
4. On selection, write `${pfx}${selected}` to `LBUFFER`; on cancel, buffer is unchanged

```zsh
# Core fzf invocation
selected=$(printf '%s\n' "${cands[@]}" | fzf \
    --height=~10 \
    --layout=reverse \
    --no-sort \              # preserve _finsh_filter's priority ordering
    --query="$typed" \       # pre-fill with user's original input for further filtering
    --color='...' \          # ayu_light color scheme
    2>/dev/null)
```

`--no-sort` preserves the Pass 1→2c priority order from `_finsh_filter`
and prevents fzf from re-ranking by its own match score.

### State Cleanup

| Timing | Action |
|--------|--------|
| New completion round starts (widget top) | Explicitly zero `_FINSH_CANDS / _FINSH_IDX / _FINSH_PFX / _FINSH_WORD` |
| Before fzf popup is launched | Same (after snapshotting, immediately zero) |
| Another key triggers `zle-line-pre-redraw` | When `$LASTWIDGET ≠ _finsh_complete`, zero state and call `zle -M ""` |

> ⚠️ **Modification notes**
> - All three conditions for the 2nd Tab trigger must be satisfied; omitting the buffer check leads to stale state being reused (Bug 9)
> - `_FINSH_WORD` stores the word **after the `--` prefix has been prepended** for opts-only tools (e.g. user typed `bu`, `_FINSH_WORD` is `--bu`). This way the fzf query directly matches `--build` candidates — this is intentional
> - `zle -M` does not support ANSI escape codes (ESC is displayed as `^[`); the candidate list can only use plain text + `[brackets]` markers

---

## History Autosuggestion

Similar to zsh-autosuggestions: shows the remainder of a matching history entry in gray after the cursor as the user types; right arrow accepts it.

### Workflow

```
User types "git co"
     │
     └─ zle-line-pre-redraw fires _finsh_update_suggestion
          │
          ├─ Search $history from the most recent event number backward
          │  for the first entry starting with "git co"
          │  → finds "git commit -m fix" → suggestion suffix " mmit -m fix"
          │
          ├─ POSTDISPLAY=" mmit -m fix"
          └─ region_highlight+=( "N M fg=8 memo=finsh-sug" )  → displayed in gray
```

### Key Variables

| Variable | Type | Purpose |
|----------|------|---------|
| `POSTDISPLAY` | ZLE built-in scalar | Text shown after cursor that does not enter the buffer |
| `region_highlight` | ZLE built-in array | Specifies highlight style for arbitrary ranges |
| `_FINSH_SUGGESTION` | global scalar | Current suggestion suffix (cached) |
| `_FINSH_SUGGESTION_NEEDLE` | global scalar | `LBUFFER` from last search (avoids repeated sort/search) |

### Highlight Mechanism

`region_highlight` entry format: `"start end style memo=token"`, with start/end based on `${#BUFFER}`.
Since POSTDISPLAY starts exactly at `${#BUFFER}`:

```zsh
local p=${#BUFFER}
region_highlight+=( "${p} $((p + ${#_FINSH_SUGGESTION})) fg=8 memo=finsh-sug" )
```

`memo=finsh-sug` is this plugin's identifier; clearing is done by exact match, leaving other plugins unaffected:

```zsh
region_highlight=( ${region_highlight:#*memo=finsh-sug} )
```

### Coexistence with Completion

`_finsh_pre_redraw` immediately clears `POSTDISPLAY` and returns when `LASTWIDGET == "_finsh_complete"`, so the candidate list and the gray suggestion never appear simultaneously.

### Right Arrow Key

```zsh
_finsh_autosuggest_accept() {
    if [[ -n "$POSTDISPLAY" ]]; then
        LBUFFER="${LBUFFER}${POSTDISPLAY}"   # merge suggestion into buffer
        POSTDISPLAY=""
        ...
    else
        zle forward-char   # fall back to native behavior when no suggestion
    fi
}
```

Binds both `^[[C` (most terminals) and `^[OC` (some terminals) for the right arrow escape sequences.

> ⚠️ **Modification notes**
> - **`zle-line-finish` fires too late**: ZLE has already completed final rendering and printed to the terminal; clearing `POSTDISPLAY` there has no effect. Must wrap `accept-line` instead
> - **Do not reset `_FINSH_SUGGESTION_NEEDLE` to `""`**: after resetting, `pre-redraw` sees `LBUFFER != needle`, re-searches history, and writes the suggestion back to `POSTDISPLAY`, undoing the clear. The correct approach: after clearing, set the needle to `"$LBUFFER"` so `_finsh_update_suggestion` hits the cache and reuses `_FINSH_SUGGESTION=""`
> - `${(Onk)history}` without outer quotes: `k` acts as an expansion flag; word-splitting correctly splits it into individual numeric elements. `"${(@On)${(k)history}}"` is wrong — `${(k)history}` expands to a scalar, and the outer `@` treats the entire string as a single element
