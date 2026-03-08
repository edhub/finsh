> English documentation: [subcommand.md](subcommand.md)

# 子命令 / 选项补全与 compadd hook

> 返回 [DESIGN.md](DESIGN.md)

---

## 子命令 / 选项补全

### 有注册补全函数（`$_comps[$cmd]` 非空）

走 `zle -C` 捕获路径，详见下一节。设 `_ble_registered=1`。

**重要**：部分补全函数（如 `_hx`）使用 `_arguments`，其底层 `comparguments` 是 C builtin，**完全绕过** function-level `compadd` hook，导致 `_FINSH_POOL` 永远为空。这种情况下会自动降级到 `--help` 解析路径，不再静默退出。

### `--help` 解析（`_finsh_parse_help` 状态机）

`_finsh_parse_help` 是单次扫描状态机，先识别 section header 再按状态提取。

```
初始状态：flat（启发式，适用于无 section 的工具，如 git）

Section header 识别条件：行长 ≤ 40 chars（过滤长描述句）且首字母开头
  *commands* / *subcommands*:  → subcmds（提取缩进子命令）
  *options*  / *flags*:        → opts   （提取 --flag）
  全大写 header（USAGE: ARGS:） → other  （整段跳过）
```

行长上限 40 是关键防线，用于区分 section header（如 `Commands:`）和正常描述句（如 git 的 `These are common Git commands used in various situations:`）。

**各状态提取规则**：

| 状态 | 子命令提取 | 选项提取 |
|------|-----------|---------|
| `subcmds` | 1-8 空格缩进 + 小写首词；逗号列表拆分 | — |
| `opts` | — | `--flag` 行（带或不带 `-x,` 短格式前缀） |
| `other` | — | — |
| `flat` | 2-8 空格缩进 + 名称后 **2+** 空格间距（过滤 `  hx [FLAGS]...` 类 USAGE 行）；逗号列表 | `--flag` 行 |

`flat` 状态的 2+ 空格间距要求用于过滤两类假阳性：
- `    hx [FLAGS]...`：名称 `hx` 后只有 1 空格 → 不匹配
- 35+ 空格对齐续行（如 hx 的 `or 'all'...`）：缩进超过 8 → 不匹配

### man page 解析（`_finsh_parse_man`）

`_finsh_parse_man` 是 `--help` 无结果时的最终兜底，专为 BSD/POSIX 工具设计（如 `ssh`、`cp`、`find` 等无 `--help` 选项的工具）。

调用方式：`man -P cat $cmd | col -bx`，结果缓存在 `_FINSH_HELP_CACHE["man:$cmd"]`。

**section header 检测**（与 `--help` 格式的差异）：

| 格式 | 示例 | 说明 |
|------|------|------|
| `--help` 风格 | `Commands:` | 首字母开头 + 冒号 |
| man page 风格 | `COMMANDS` | 全大写，无冒号，行长 ≤ 40 |

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

### --help → man page 回退链

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

### 无子命令但有选项时的路由（opts-only 工具）

对 `node`、`hx` 等只有选项没有子命令的工具，word 不以 `-` 开头时也应路由到选项池：

```zsh
if [[ "$word" == -* ]]; then
    pool=( "${_FINSH_PARSE_OPTS[@]}" )
elif (( $#_FINSH_PARSE_SUBCMDS )); then
    pool=( "${_FINSH_PARSE_SUBCMDS[@]}" )
elif (( $#_FINSH_PARSE_OPTS )); then
    # 无子命令但有选项：把 opts 纳入 pool
    # word 非空时补 "--" 前缀，使 "bu" 能前缀匹配 "--build-sea"
    pool=( "${_FINSH_PARSE_OPTS[@]}" )
    [[ -n "$word" ]] && word="--${word}"
fi
```

**效果**：`node bu<Tab>` → `word` 变 `"--bu"` → 前缀匹配 `--build-sea`、`--build-snapshot` 等。`_FINSH_PFX` 仍为原 `prefix`（`"node "`），候选直接替换原始 word（`"bu"` 被替换为 `"--build-sea"`）。

### pool 为空时的回退策略

| 情况 | 行为 |
|------|------|
| 有注册补全函数，capture 无结果，`--help` 无结果，man page 也无结果 | **静默退出**（避免 `_just` 无 justfile 时产生 `=`）|
| 无注册补全函数，help 和 man page 都无结果 | **fallback** `zle complete-word`（通常做文件补全）|

> ⚠️ **修改注意**
> - `_FINSH_HELP_CACHE` 是 `typeset -gA`，key=命令词空格拼接，同一 session 只 fork 一次；修改 help 解析逻辑后注意缓存 key 的一致性
> - **`_ble_registered` 标志**：有注册补全函数（`_comps[$cmd]` 非空）时设为 1；pool 为空时 `_ble_registered=1` → 静默退出，`=0` → fallback `zle complete-word`，避免 `_just` 等在无 justfile 时因二次触发产生 `=` 等噪声
> - `local` 声明须放在 `while`/`for` 循环体**外**；zle widget 上下文中，循环体内的 `typeset` 每次迭代都会把初始化副作用（如 `var=''`）输出到终端

---

## `compadd` hook 与 `zle -C`

### 为什么必须用 `zle -C`

```
普通 widget → zle complete-word → C 层直调 compadd builtin  ← hook 无效 ✗

普通 widget → zle -C _cap complete-word _capture
                          → _main_complete → _git / _docker …
                                               → compadd()   ← hook 生效 ✓
```

### 调用流程

```zsh
# 1. 注册临时 completion widget
zle -C _finsh_cap complete-word _finsh_capture

# 2. 保存/设置 LBUFFER，让补全系统在"空词"语境下生成完整候选
{
    LBUFFER="$prefix"   # 去掉当前词
    RBUFFER=""; CURSOR=${#LBUFFER}
    zle _finsh_cap 2>/dev/null
} always {
    LBUFFER="$slbuf"; RBUFFER="$srbuf"   # 恢复，无论成功/异常
    zle -D _finsh_cap 2>/dev/null
    unfunction compadd 2>/dev/null
}

pool=( "${_FINSH_POOL[@]}" )
```

### `_finsh_capture` 实现要点

- 在 completion context 内定义 `function compadd()`，覆盖 builtin
- **不调用 `builtin compadd`**：候选只写 `_FINSH_POOL`，不写入 zsh completion buffer，否则退出时 zsh 触发 "do you wish to see all N possibilities?" 提示
- 始终 `return 0`，防止补全函数走 fallback 分支漏掉候选
- `_FINSH_POOL` 必须是 `typeset -ga`（全局），completion context 内无法访问外层 widget 的 `local` 变量
- `_finsh_capture` 定义在**文件顶层**（非函数内部），`zle -C` 才能找到

### `compadd` 参数解析

| 参数 | 处理方式 |
|------|----------|
| `-O`/`-D`/`-A` | 内部数组操作，`return 0` 跳过整个调用 |
| `-a name` | 展开数组 `"${(@P)name}"` 加入 pool |
| `-k name` | 展开哈希键 `"${(kP)name}"` 加入 pool |
| `-[PSpsWdJVXxrRMFtoEIi]`（单独形式）| 带参 flag，`skip_next=1` 跳过下一个参数 |
| `-*`（组合 flag，如 `-qS`、`-ld`）| 若含上述字符则 `skip_next=1`，否则忽略 |
| `--` | 之后全部为候选词 |
| 其余非 `-` 开头 | 候选词，加入 pool |

> ⚠️ **修改注意**
> - `-[ODA]` 整个调用跳过；`-a`/`-k` 展开数组/哈希键；单独带参 flag 用精确匹配；**组合 flag 用正则检测含参字符**（`_describe` 会传 `-qS` 不是 `-q -S`，若不检测，suffix 值如 `=` 会被当候选词）
> - `_FINSH_POOL` 必须 `typeset -ga`；`_finsh_capture` 必须定义在文件顶层
