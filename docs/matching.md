# Match Priority and Path Completion

> Back to [DESIGN.md](../DESIGN.md)

> 中文文档：[matching.zh.md](matching.zh.md)

---

## Match Priority (`_finsh_filter`)

Passes degrade in order; the first hit wins. **All passes first pre-filter by first letter** (the candidate's first character must match `word[1]`), preventing pure subsequence matching from hitting large numbers of unrelated entries in big candidate pools.

| Pass | Name | Example |
|------|------|---------|
| pre | First-letter pre-filter | `pi…` only runs against candidates starting with `p` |
| 1 | Exact prefix | `pi` → `pi-claude` |
| 2a | Substring | `pi-cl` → `pi-claude` |
| 2b | Head-anchored subsequence | `piclaud` → `pi-claude` (first letter `p` anchored, rest `iclaud ⊆ i-claude`) |
| 2c | Pure subsequence | `pclaud` → `pi-claude` (`*p*c*l*a*u*d*`, first letter guaranteed by pre-filter) |

All passes escape glob metacharacters with `${(b)word}` before matching, preventing issues with inputs like `--release` that contain special characters.

> ⚠️ **Modification notes**
> - Results are written to the global `_FINSH_FILTERED` (no subshell); glob matching uses `${(b)word}` for escaping — any changes must stay consistent
> - When `word` is empty, `_FINSH_FILTERED` is left empty and the caller uses the raw pool directly
> - **The first-letter pre-filter must not be removed**: `pool=( ${(M)pool:#${(b)word[1]}*} )`. Without it, Pass 2c pure subsequence matches vast numbers of unrelated entries in large pools (cross-first-letter substring matching in Pass 2a also disappears — this is intentional: typing `claude` should complete things starting with `c`)

---

## Path Completion

```zsh
# word = "~/dev/fzf-b"
dir  = word:h  = "~"          # dirname
base = word:t  = "fzf-b"      # basename, used for filtering
xdir = dir with ~ expanded → "$HOME"
sep  = "~/"                    # preserved in output to keep original ~/
xbase = xdir with trailing slash stripped

# glob (includes dotfiles via D qualifier)
names=( "${xbase}"/*(.DN) "${xbase}"/*(/DN) )
names=( "${names[@]#${xbase}/}" )   # strip path prefix, keep basename only

# Special case for root directory (avoid //Applications when xbase="")
if [[ -z "$xbase" ]]; then
    names=( /*(.DN) /*(/DN) )
fi
```

> ⚠️ **Modification notes**
> - `~` does not expand inside double quotes; use `${dir/#\~/$HOME}` to manually replace the prefix
> - Glob `*` does not match dotfiles (`.zshrc` etc.) by default; add the `D` qualifier: `*(.DN)` / `*(/DN)`
> - When at root, `xbase=""` without special-casing produces double-slash paths like `//Applications`
