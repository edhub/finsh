# finsh

> Pronounced **"finish"** — `fin` (fish fin, a nod to Fish shell) + `sh` (shell), with the `i` intentionally dropped.

Fish shell introduced a "what-you-see-is-what-you-get" completion experience — candidates are always visible, and fuzzy matching lets any substring hit the target.
Once you've used it, going back to zsh's plain Tab feels like something's missing.

[ble.sh](https://github.com/akinomyoga/ble.sh) proved that replicating this experience in Bash is possible.
So **finsh** was born — bringing the same completion philosophy to zsh users on macOS.

> 中文文档：[README.zh.md](README.zh.md)

---

## The Core Problem

Solutions like `fzf-tab` rely on zsh's native completion — which already filtered candidates with **exact prefix** matching:
type `piclaud` hoping to match `pi-claude`, and zsh strips everything that doesn't start with `piclaud`,
leaving fzf with an empty list.

finsh collects raw candidates at the **ZLE layer**, bypassing zsh's prefix truncation entirely.

---

## Features

- **Two-phase completion**: first Tab shows the candidate list (show mode); second Tab fills in and cycles through
- **Live re-filtering**: in show mode, keep typing to filter candidates in real time without pressing Tab again
- **Multi-level fuzzy matching**: prefix → substring → head-anchored subsequence → pure subsequence
- **History autosuggestion**: shows the matching history suffix in gray; `→` accepts in one keystroke
- **Path completion**: includes dotfiles, multi-level glob, supports `~` expansion
- **Subcommand / option completion**: prefers zsh-registered completion functions, falls back to parsing `--help` output

---

## Installation

### Manual

```zsh
mkdir -p ~/.zsh/plugins
curl -fsSL https://raw.githubusercontent.com/edhub/finsh/main/finsh.zsh \
    -o ~/.zsh/plugins/finsh.zsh
```

Add to `~/.zshrc`:

```zsh
source ~/.zsh/plugins/finsh.zsh
```

### zinit

```zsh
zinit light edhub/finsh
```

### Oh My Zsh

```zsh
git clone https://github.com/edhub/finsh \
    ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/finsh
```

Add `finsh` to the `plugins` list in `~/.zshrc`:

```zsh
plugins=(... finsh)
```

---

The plugin initializes itself automatically: on macOS it adds the Homebrew completion directory to `fpath` and runs `compinit` if needed.

> **Diagnostics**: if subcommand completion isn't working, run `print $_comps[git]`.
> An empty result means Homebrew isn't installed or completion files are missing (`brew install zsh-completions`).

---

## Key Bindings

| Key | Behavior |
|-----|----------|
| `Tab` (1st press) | Fuzzy filter → show candidate list at the bottom (show mode) |
| Continue typing | Re-filter candidates in real time |
| `Tab` (2nd press) | Fill in first candidate, enter cycle mode |
| `Tab` (in cycle mode) | Cycle to the next candidate |
| `Shift+Tab` | Native zsh completion (preserves context-aware behavior) |
| `→` / `Ctrl+F` | Accept history autosuggestion; falls back to forward-char if none |
| Any other key | Accept current candidate, list disappears |

---

## Tab Completion Behavior

### 1st Tab — Show Mode

After pressing Tab, all candidates are shown at the bottom immediately. The command line **stays unchanged** so you can keep typing to filter:

```
❯ brew li
list  link  linkage  livecheck
```

Continue typing `nk`:

```
❯ brew link
link  linkage
```

### 2nd Tab — Fill and Cycle

Press Tab again to fill in the first candidate and enter cycle mode; keep pressing Tab to cycle:

```
❯ brew link
[link]  linkage
```

```
❯ brew linkage
link  [linkage]
```

---

## Match Priority

All passes pre-filter by first letter before running. Passes degrade in order; the first hit wins:

| Pass | Name | Example |
|------|------|---------|
| pre | First-letter pre-filter | `pi…` only runs against candidates starting with `p` |
| 1 | Exact prefix | `pi` → `pi-claude` |
| 2a | Substring | `pi-cl` → `pi-claude` |
| 2b | Head-anchored subsequence | `piclaud` → `pi-claude` |
| 2c | Pure subsequence | `pclaud` → `pi-claude` |

---

## Completion Scenarios

| Scenario | Candidate source |
|----------|-----------------|
| First word (command name) | `commands` + visible functions + aliases + builtins |
| Word containing `/` (path) | Directory glob for the matching level (includes dotfiles), filtered by basename |
| Subcommand/option with registered completion | `zle -C` + `compadd` hook intercepts zsh native completion |
| Subcommand/option without registered completion | Parses `$cmd [subcmd…] --help` output |
| None of the above yield results | Falls back to `zle complete-word` (no registered function); silently exits (registered function exists) |

---

## Files

| File | Description |
|------|-------------|
| `finsh.zsh` | Single implementation file |
| `DESIGN.md` | Design document (architecture, implementation details, bug history) |
| `tests/test-help-parser.zsh` | Unit tests for `_finsh_parse_help` and `_finsh_filter` |
