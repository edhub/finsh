# fzf-ble-complete — 设计文档

> 安装与快速上手见 [README.md](README.md)。

---

## 背景

fzf-tab 的局限：zsh 在把候选交给 fzf-tab **之前**已经做了前缀过滤，所以输入
`piclaud` 时 zsh 找不到任何候选，fzf-tab 根本拿不到 `pi-claude`。

解决方向：**自定义 ZLE widget**，完全绕过 zsh 的过滤，自己收集候选，再用
ble.sh 的多级匹配逻辑筛选，最后通过 Tab 循环选择。

---

## 补全流程总览

```
Tab 键
 │
 ├─ 循环检查：LASTWIDGET==本widget && _BLE_CANDS非空
 │            && LBUFFER==_BLE_PFX+_BLE_CANDS[_BLE_IDX]
 │            → 循环到下一候选，展示列表
 │
 └─ 新一轮补全
      │
      ├─ word 含 / → 路径补全（glob + dotfile）
      │
      ├─ prefix 全空白 → 命令名补全（commands/functions/aliases/builtins）
      │
      └─ 子命令/选项补全
           │
           ├─ _comps[$cmd] 非空 → zle -C capture（hook compadd 截获候选）
           │                       pool=0 且 _ble_registered=1 → 静默退出
           │
           └─ _comps[$cmd] 为空 → 解析 $cmd [subcmd…] --help
                                   word 以 - 开头 → 选项池
                                   否则           → 子命令池
                                   pool=0         → fallback zle complete-word
```

---

## 匹配优先级（`_ble_filter`）

逐级降级，命中即停止。**所有 pass 在运行前都会先按首字母预过滤**（候选首字母必须与 word[1] 相同），避免纯 subsequence 在大型候选池中命中大量不相关条目。

| Pass | 名称 | 示例 |
|------|------|------|
| pre | 首字母预过滤 | `pi…` 只在 `p` 开头的候选里跑 |
| 1 | 精确前缀 | `pi` → `pi-claude` |
| 2a | substring | `pi-cl` → `pi-claude` |
| 2b | head-anchored subsequence | `piclaud` → `pi-claude`（首字母 `p` 锚定，其余 `iclaud ⊆ i-claude`）|
| 2c | pure subsequence | `pclaud` → `pi-claude`（`*p*c*l*a*u*d*`，首字母已由 pre 保证）|

所有 pass 用 `${(b)word}` 转义 glob 元字符后再匹配，防止 `--release`
等含特殊字符的词出问题。`print -l` 一律加 `--` 截断参数解析（`print -l "--release"`
否则会把 `--release` 解析成 flag）。

---

## 路径补全

```zsh
# word = "~/dev/fzf-b"
dir  = word:h  = "~"          # dirname
base = word:t  = "fzf-b"      # basename，用于过滤
xdir = dir 展开 ~ → "$HOME"
sep  = "~/"                    # 还原到输出时保留原始 ~/
xbase = xdir 去尾斜杠

# glob（含 dotfile，用 D qualifier）
names=( "${xbase}"/*(.DN) "${xbase}"/*(/DN) )
names=( "${names[@]#${xbase}/}" )   # 剥离路径前缀，只保留 basename

# 根目录特殊处理（xbase="" 时避免 //Applications）
if [[ -z "$xbase" ]]; then
    names=( /*(.DN) /*(/DN) )
fi
```

**关键坑**：
- `~` 在双引号内不展开，必须用 `${dir/#\~/$HOME}` 手动替换
- glob `*` 默认不匹配 dotfile（`.zshrc` 等），需加 `D` qualifier
- 根目录时 `xbase=""` 若不特判会产生 `//Applications` 双斜杠路径

---

## 子命令 / 选项补全

### 有注册补全函数（`$_comps[$cmd]` 非空）

走 `zle -C` 捕获路径，详见下一节。设 `_ble_registered=1`。

### 无注册补全函数

解析 `$cmd [非-选项词…] --help`，按当前词类型分流：

```zsh
# prefix="cargo build -v " → help_words=(cargo build) → 运行 cargo build --help
for _ble_w in ${(Az)prefix}; do
    [[ "$_ble_w" == -* ]] || _ble_help_words+=("$_ble_w")
done

if [[ "$word" == -* ]]; then pool=( "${_ble_opts[@]}"   )   # --flag 候选
else                         pool=( "${_ble_subcmds[@]}" )   # 子命令候选
fi
```

**选项行正则**：`'^[[:space:]]+((-[a-zA-Z],?[[:space:]]+)?)(--([a-zA-Z][a-zA-Z0-9-]*))'`
→ 匹配 `  -v, --verbose` 和 `      --release` 两种格式，提取 `--flag` 部分。

**子命令行正则**：`'^    ([a-z][-a-z0-9]*)'`
→ 恰好 4 空格缩进，首词小写字母开头（如 cargo 的 `    build    Compile…`）。

### pool 为空时的回退策略

| 情况 | 行为 |
|------|------|
| 有注册补全函数，capture 无结果 | **静默退出**（避免 `_just` 无 justfile 时产生 `=`）|
| 无注册补全函数，help 也无结果 | **fallback** `zle complete-word`（通常做文件补全）|

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
zle -C _fzf_ble_cap complete-word _fzf_ble_capture

# 2. 保存/设置 LBUFFER，让补全系统在"空词"语境下生成完整候选
{
    LBUFFER="$prefix"   # 去掉当前词
    RBUFFER=""; CURSOR=${#LBUFFER}
    zle _fzf_ble_cap 2>/dev/null
} always {
    LBUFFER="$slbuf"; RBUFFER="$srbuf"   # 恢复，无论成功/异常
    zle -D _fzf_ble_cap 2>/dev/null
    unfunction compadd 2>/dev/null
}

pool=( "${_FZF_BLE_POOL[@]}" )
```

### `_fzf_ble_capture` 实现要点

- 在 completion context 内定义 `function compadd()`，覆盖 builtin
- **不调用 `builtin compadd`**：候选只写 `_FZF_BLE_POOL`，不写入 zsh
  completion buffer，否则退出时 zsh 触发 "do you wish to see all N
  possibilities?" 提示
- 始终 `return 0`，防止补全函数走 fallback 分支漏掉候选
- `_FZF_BLE_POOL` 必须是 `typeset -ga`（全局），completion context 内
  无法访问外层 widget 的 `local` 变量
- `_fzf_ble_capture` 定义在**文件顶层**（非函数内部），`zle -C` 才能找到

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

---

## 循环模式

```zsh
# 状态变量（全局，跨 widget 调用）
typeset -ga _BLE_CANDS   # 候选列表
typeset -gi _BLE_IDX=0   # 当前索引（1-based）
typeset -g  _BLE_PFX=""  # 候选前缀（LBUFFER 的不变部分）
```

### 循环触发条件（三个都要满足）

```zsh
[[ "$LASTWIDGET" == "_fzf_ble_complete" ]]                          # 上一个 widget 是本 widget
&& (( $#_BLE_CANDS ))                                               # 有候选
&& [[ "$LBUFFER" == "${_BLE_PFX}${_BLE_CANDS[$_BLE_IDX]}" ]]       # buffer 与上次一致
```

第三个条件是关键——验证当前 buffer 确实处于上次设好的循环位置，
防止旧 `_BLE_CANDS` 脏状态被误用。

### 状态清理

- **新一轮补全开始时**：widget 顶部显式清零
- **其他键触发 `zle-line-pre-redraw`**：检测到 `$LASTWIDGET ≠ _fzf_ble_complete` 时清零并调 `zle -M ""`

---

## 已修复的 Bug

### 路径补全

**Bug 1 — `~` 路径 glob 失败**（`cd ~/dev/fzf<tab>`）

原因：`~` 在双引号内不展开，`"${~dir}"` 语法在此场景下无效。  
修法：`${dir/#\~/$HOME}` 手动替换前缀。

**Bug 2 — 根目录双斜杠**（`cd /Use<tab>` → `//Users`）

原因：`dir="/"` 时 `xbase="/"` 拼接产生 `"/"/*` = `//Applications` 等。  
修法：`xbase="${xdir%/}"` 去尾斜杠，并对 `xbase=""` 单独走 `/*(.DN)` glob。

**Bug 3 — dotfile 不出现**（`vi ~/.zsh<tab>` → `AndroidStudioProjects`）

原因：glob `*` 默认不匹配 `.` 开头的文件，filter 无命中后 show=pool，
首个字母序候选是非 dotfile。  
修法：glob qualifier 加 `D`，即 `*(.DN)` / `*(/DN)`。

---

### help 解析

**Bug 4 — `cargo bu<tab>` 补全到本地文件**

原因：`_comps[cargo]` 为空，zle-C 路径跳过，help 解析路径也跳过，
pool 为空后 fallback `zle complete-word` → `_default` → 文件补全。  
修法：无注册补全函数时解析 `cargo --help`，word 不以 `-` 开头则取
4-空格缩进子命令行作为 pool。

**Bug 5 — `cargo build --rel<tab>` 补全失败**

原因：`--rel` 以 `-` 开头，但 pool 来自 `_ble_subcmds`（空）。  
修法：help 解析时 word 以 `-` 开头则取选项行（`--flag` 格式）作为 pool。
`print -l --` 防止 `--release` 等被 `print` 解析为 flag。

---

### 语言 / 语法陷阱

**Bug 6 — `${(z)prefix}[1]` 取到首字符而非首词**

原因：`${(z)prefix}` 返回数组，但下标写在 `${}` 外面时取的是字符串第一个字符。  
修法：改为 `${${(Az)prefix}[1]}`，`(A)` 将结果强制为数组后再取 `[1]`。

---

### compadd hook 解析

**Bug 8 — `just <tab>` 无 justfile 时补全到 `=`（根本原因）**

原因：`_describe` 传给 `compadd` 的是组合 flag `-qS`（不是 `-q -S`）。
hook 里 `-qS` 匹配 `-*` 分支被忽略，下一个参数 `=`（suffix 值）没被跳过，
直接当候选词进了 pool，最终 pool=`("=")` → 唯一候选直接补全。  
修法：`-*` 分支加检测，若组合 flag 中含有带参字符（`[PSpsWdJVXxrRMFtoEIi]`）
则 `skip_next=1`。

---

### 循环状态

**Bug 7 — `just <tab>` 无 justfile 时补全到 `=`（表象）**

原因：`_comps[just]=_just`，zle-C capture 运行，pool 为空，
fallback `zle complete-word` 再次触发 `_just`，在真实 completion context 下
将 `=` 作为 suffix 插入 buffer。  
修法：引入 `_ble_registered` 标志，有注册补全函数但 pool 为空时**静默退出**，
不 fallback。

**Bug 9 — 循环模式误用旧状态**

原因：循环检查只看 `$LASTWIDGET` 和 `$#_BLE_CANDS`，不验证 buffer 位置。
旧 bug 留下 `_BLE_CANDS=("=")` 后，下次 Tab 直接进循环复现旧问题。  
修法：循环条件加 `[[ "$LBUFFER" == "${_BLE_PFX}${_BLE_CANDS[$_BLE_IDX]}" ]]`，
buffer 不匹配则视为新一轮补全。

---

### 匹配过于宽松

**Bug 10 — 输入 `picli` 时补全出大量无关候选**

原因：Pass 2c（pure subsequence）生成 `*p*i*c*l*i*`，在几千个命令的 pool 里
能命中任意包含这五个字母（按序）的字符串，与输入完全无关的命令也会进入候选。  
修法：在 `_ble_filter` 所有 pass 运行前加首字母预过滤，pool 收窄到首字母与
`word[1]` 相同的候选：`pool=( ${(M)pool:#${(b)word[1]}*} )`。
副作用：Pass 2a 的跨首字母 substring 匹配（如 `claude` → `pi-claude`）同时消除，
属预期行为——输入 `claude` 应补全以 `c` 开头的东西。

**Bug 11 — 无匹配时 dump 全 pool**

原因：`_BLE_FILTERED` 为空时，`show` fallback 到完整 pool，几千条候选全部展示。  
修法：主 widget 中 word 非空但无匹配时直接 return，只有 word 为空时才展示全 pool。

```zsh
if (( $#_BLE_FILTERED )); then
    show=("${_BLE_FILTERED[@]}")
elif [[ -z "$word" ]]; then
    show=("${pool[@]}")
else
    return   # 有输入但无匹配，安静退出
fi
```
