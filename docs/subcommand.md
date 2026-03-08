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

### man page 解析（`_finsh_parse_man`）

`_finsh_parse_man` 是 `--help` 无结果时的最终兜底，专为 BSD/POSIX 工具设计（如 `ssh`、`cp`、`find` 等无 `--help` 选项的工具）。

调用方式：`man -P cat $cmd | col -bx`，结果缓存在 `_FINSH_HELP_CACHE["man:$cmd"]`。

**section header 检测**（与 `--help` 格式的差异）：

| 格式 | 示例 | 说明 |
|------|------|------|
| `--help` style | `Commands:` | 首字母开头 + 冒号 |
| man page style | `COMMANDS` | 全大写，无冒号，行长 ≤ 40 |

**各状态提取规则**：

| 状态 | 规则 |
|------|------|
| `subcmds` | 3-12 空格缩进 + 小写连字符名 + `" ["` 或行尾；`" ["` 要求过滤 `"target-session is tried"` 类散文行 |
| `opts` | `--flag`（带或不带 `-x,` 前缀）＋ 单横杠 `-x` 或 `-xy`（3-12 空格 + 1+ 空格间距） |
| `other` | 仅 BSD 内嵌选项模式：3-12 空格 + `-x/-xy` + 1+ 空格；用于 DESCRIPTION 内嵌选项（ssh、cp 等） |

**关键设计：`other` state 的 BSD 选项检测**

BSD/macOS 工具（`ssh`、`cp` 等）无独立 `OPTIONS` section，选项嵌在 `DESCRIPTION` 内：
```
     -4      Forces ssh to use IPv4 addresses only.
     -H    If the -R option is specified, symbolic links are followed.
     -b bind_address
```
`DESCRIPTION` 触发 `other` state；`3-12空格 + -x + 1+空格` 模式在此 state 检测，捕获所有这类选项。

**已知限制**：tmux 的命令分散在 `CLIENTS AND SESSIONS`、`WINDOWS AND PANES` 等子 section，不在 `COMMANDS` section 内，因此 man page 解析对 tmux subcommand 补全无效。tmux 建议使用 `tmux list-commands` 获取完整命令列表。

### `--help` → man page 回退链

```
_finsh_collect_subcmd_pool 内的完整回退链：

1. zle -C 捕获（_comps[$cmd] 非空时）
   │  pool 非空 → 使用
   │  pool 空（_arguments 绕过 hook）↓
2. $cmd --help 解析（_finsh_parse_help）
   │  有结果 → 路由到 subcmds/opts 池
   │  无结果 ↓
3. man -P cat $cmd | col -bx 解析（_finsh_parse_man）
   │  有结果 → 路由到 subcmds/opts 池
   │  无结果 → 按 _registered 决定静默退出或 fallback complete-word
```

man page 解析在两种情况均尝试（不区分 `_registered`）：
- 无注册补全函数（`_registered=0`）
- 有注册函数但 `_arguments` 绕过 hook（`_registered=1`，如 `_ssh`、`_cp`）

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

### pool 为空时的回退策略

| 情况 | 行为 |
|------|------|
| 有注册补全函数，capture 无结果，`--help` 无结果，man page 也无结果 | **静默退出** |
| 无注册补全函数，help 和 man page 都无结果 | **fallback** `zle complete-word` |

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
