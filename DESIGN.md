# fzf-ble-complete — 设计文档

> 安装与快速上手见 [README.md](README.md)。

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

所有 pass 用 `${(b)word}` 转义 glob 元字符后再匹配，防止 `--release` 等含特殊字符的词出问题。

> ⚠️ **修改注意**
> - 结果写入全局 `_BLE_FILTERED`（不开 subshell），glob 匹配中用 `${(b)word}` 转义元字符，任何修改都要保持一致
> - word 为空时 `_BLE_FILTERED` 置空，调用方直接用原始 pool
> - **首字母预过滤不得移除**：`pool=( ${(M)pool:#${(b)word[1]}*} )`，否则 Pass 2c 的纯 subsequence 会在大型候选池中命中大量无关条目（Pass 2a 的跨首字母 substring 匹配也随之消失，属预期行为——输入 `claude` 应补全以 `c` 开头的东西）

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

> ⚠️ **修改注意**
> - `~` 在双引号内不展开，必须用 `${dir/#\~/$HOME}` 手动替换前缀
> - glob `*` 默认不匹配 dotfile（`.zshrc` 等），需加 `D` qualifier：`*(.DN)` / `*(/DN)`
> - 根目录时 `xbase=""` 若不特判会产生 `//Applications` 双斜杠路径

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
若该行含逗号（npm 的 `    access, adduser, ..., install, ...` 格式），则按 `,` 拆分后逐词校验提取，否则只取首词。

### pool 为空时的回退策略

| 情况 | 行为 |
|------|------|
| 有注册补全函数，capture 无结果 | **静默退出**（避免 `_just` 无 justfile 时产生 `=`）|
| 无注册补全函数，help 也无结果 | **fallback** `zle complete-word`（通常做文件补全）|

> ⚠️ **修改注意**
> - `_BLE_HELP_CACHE` 是 `typeset -gA`，key=命令词空格拼接，同一 session 只 fork 一次；修改 help 解析逻辑后注意缓存 key 的一致性
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
- **不调用 `builtin compadd`**：候选只写 `_FZF_BLE_POOL`，不写入 zsh completion buffer，否则退出时 zsh 触发 "do you wish to see all N possibilities?" 提示
- 始终 `return 0`，防止补全函数走 fallback 分支漏掉候选
- `_FZF_BLE_POOL` 必须是 `typeset -ga`（全局），completion context 内无法访问外层 widget 的 `local` 变量
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

> ⚠️ **修改注意**
> - `-[ODA]` 整个调用跳过；`-a`/`-k` 展开数组/哈希键；单独带参 flag 用精确匹配；**组合 flag 用正则检测含参字符**（`_describe` 会传 `-qS` 不是 `-q -S`，若不检测，suffix 值如 `=` 会被当候选词）
> - `_FZF_BLE_POOL` 必须 `typeset -ga`；`_fzf_ble_capture` 必须定义在文件顶层

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

第三个条件是关键——验证当前 buffer 确实处于上次设好的循环位置，防止旧 `_BLE_CANDS` 脏状态被误用。

### 状态清理

- **新一轮补全开始时**：widget 顶部显式清零
- **其他键触发 `zle-line-pre-redraw`**：检测到 `$LASTWIDGET ≠ _fzf_ble_complete` 时清零并调 `zle -M ""`

> ⚠️ **修改注意**
> - 循环条件三个都要满足，缺少 buffer 验证会导致旧 `_BLE_CANDS` 脏状态被误用
> - 用 `zle -M` 展示候选，`${#item} + 2` 做换行宽度预估

---

## 历史自动建议

类似 zsh-autosuggestions 的行为：输入时在光标后以灰色显示历史匹配项的剩余部分，按右方向键接受。

### 工作流程

```
用户输入 "git co"
     │
     └─ zle-line-pre-redraw 触发 _ble_update_suggestion
          │
          ├─ 在 $history 中从最近事件号向前搜索第一条以 "git co" 开头的记录
          │   → 找到 "git commit -m fix" → 建议后缀 " mmit -m fix"
          │
          ├─ POSTDISPLAY=" mmit -m fix"
          └─ region_highlight+=( "N M fg=8 memo=ble-sug" )  → 灰色显示
```

### 关键变量

| 变量 | 类型 | 作用 |
|------|------|------|
| `POSTDISPLAY` | ZLE 内置 scalar | 光标后显示但不进入 buffer 的文本 |
| `region_highlight` | ZLE 内置 array | 指定任意区间的高亮样式 |
| `_BLE_SUGGESTION` | global scalar | 当前建议后缀（缓存） |
| `_BLE_SUGGESTION_NEEDLE` | global scalar | 上次搜索的 LBUFFER（避免重复排序/搜索） |

### 高亮机制

`region_highlight` 条目格式：`"start end style memo=token"`，start/end 以 `${#BUFFER}` 为基准。
POSTDISPLAY 的起点恰好是 `${#BUFFER}`，所以：

```zsh
local p=${#BUFFER}
region_highlight+=( "${p} $((p + ${#_BLE_SUGGESTION})) fg=8 memo=ble-sug" )
```

`memo=ble-sug` 是本插件的标识符，清除时精确匹配，不影响其他插件：

```zsh
region_highlight=( ${region_highlight:#*memo=ble-sug} )
```

### 与补全循环共存

`_ble_pre_redraw` 在 `LASTWIDGET == "_fzf_ble_complete"` 时直接清空 `POSTDISPLAY` 并 return，补全候选列表与灰色建议不会同时出现。

### 右方向键

```zsh
_ble_autosuggest_accept() {
    if [[ -n "$POSTDISPLAY" ]]; then
        LBUFFER="${LBUFFER}${POSTDISPLAY}"   # 将建议并入 buffer
        POSTDISPLAY=""
        ...
    else
        zle forward-char   # 无建议时退化为原生行为
    fi
}
```

绑定 `^[[C`（大多数终端）和 `^[OC`（部分终端）两个右方向键转义序列。

> ⚠️ **修改注意**
> - **`zle-line-finish` 时序太晚**：ZLE 完成最终渲染后才触发，此时清空 `POSTDISPLAY` 无效，灰色文字已随行输出打印；必须包装 `accept-line`
> - **`_BLE_SUGGESTION_NEEDLE` 不能重置为 `""`**：重置后 `pre-redraw` 会判定 `LBUFFER != needle`，重新搜历史把建议写回 `POSTDISPLAY`；正确做法是清空后把 needle 设为 `"$LBUFFER"`，让 `_ble_update_suggestion` 命中缓存复用 `_BLE_SUGGESTION=""`
> - `${(Onk)history}` 不加外层引号，`k` 作为展开 flag，word-splitting 自动切分为独立数字元素；`"${(@On)${(k)history}}"` 错误——`${(k)history}` 展开为标量，外层 `@` 把整个字符串当单个元素

---

## Bug 历史

### 路径补全

**Bug 1 — `~` 路径 glob 失败**（`cd ~/dev/fzf<tab>`）

原因：`~` 在双引号内不展开，`"${~dir}"` 语法在此场景下无效。  
修法：`${dir/#\~/$HOME}` 手动替换前缀。

**Bug 2 — 根目录双斜杠**（`cd /Use<tab>` → `//Users`）

原因：`dir="/"` 时 `xbase="/"` 拼接产生 `"/"/*` = `//Applications` 等。  
修法：`xbase="${xdir%/}"` 去尾斜杠，并对 `xbase=""` 单独走 `/*(.DN)` glob。

**Bug 3 — dotfile 不出现**（`vi ~/.zsh<tab>` → `AndroidStudioProjects`）

原因：glob `*` 默认不匹配 `.` 开头的文件，filter 无命中后 show=pool，首个字母序候选是非 dotfile。  
修法：glob qualifier 加 `D`，即 `*(.DN)` / `*(/DN)`。

---

### help 解析

**Bug 4 — `cargo bu<tab>` 补全到本地文件**

原因：`_comps[cargo]` 为空，zle-C 路径跳过，help 解析路径也跳过，pool 为空后 fallback `zle complete-word` → `_default` → 文件补全。  
修法：无注册补全函数时解析 `cargo --help`，word 不以 `-` 开头则取 4-空格缩进子命令行作为 pool。

**Bug 5 — `cargo build --rel<tab>` 补全失败**

原因：`--rel` 以 `-` 开头，但 pool 来自 `_ble_subcmds`（空）。  
修法：help 解析时 word 以 `-` 开头则取选项行（`--flag` 格式）作为 pool。

**Bug 12 — `npm in<tab>` 输出 `_ble_part=''` 杂项 + 遗漏 `install`**

原因（双重）：
1. `npm --help` 的子命令以**逗号分隔平铺在同一行**（`    access, adduser, ..., install, ...`），旧逻辑只抓每行第一个词，`install` 等藏在行中间的命令全部丢失。
2. 修复时 `local _ble_part` 声明写在 `while` 循环体内，每次进入逗号分支都重新执行一次 `typeset`，zle widget 上下文把初始化副作用 `_ble_part=''` 打印到终端。

修法：
1. 子命令行含逗号时，按 `,` 拆分、去除空白、逐词校验 `'^[a-z][-a-z0-9]*$'`，全部加入 pool。
2. 把 `local _ble_part` 提到 `while` 循环**外**，与 `_ble_help_line` 合并声明，`local` 只执行一次。

---

### 语言 / 语法陷阱

**Bug 6 — `${(z)prefix}[1]` 取到首字符而非首词**

原因：`${(z)prefix}` 返回数组，但下标写在 `${}` 外面时取的是字符串第一个字符。  
修法：改为 `${${(Az)prefix}[1]}`，`(A)` 将结果强制为数组后再取 `[1]`。

**Bug 13 — 历史建议始终为空**

原因：`"${(@On)${(k)history}}"` 加了外层引号，`@` 把 `${(k)history}` 展开的标量 `"3 2 1"` 当成**单个元素**，导致 `nums=("3 2 1")`，for 循环用它查 `$history` 当然是空。  
修法：改为 `${(Onk)history}`，`k` 直接作为展开 flag，无外层引号，word-splitting 正确切分：

```zsh
nums=( ${(Onk)history} )   # ✓ 得到 ("3" "2" "1")
```

---

### compadd hook 解析

**Bug 8 — `just <tab>` 无 justfile 时补全到 `=`（根本原因）**

原因：`_describe` 传给 `compadd` 的是组合 flag `-qS`（不是 `-q -S`）。hook 里 `-qS` 匹配 `-*` 分支被忽略，下一个参数 `=`（suffix 值）没被跳过，直接当候选词进了 pool，最终 pool=`("=")` → 唯一候选直接补全。  
修法：`-*` 分支加检测，若组合 flag 中含有带参字符（`[PSpsWdJVXxrRMFtoEIi]`）则 `skip_next=1`。

---

### 循环状态

**Bug 7 — `just <tab>` 无 justfile 时补全到 `=`（表象）**

原因：`_comps[just]=_just`，zle-C capture 运行，pool 为空，fallback `zle complete-word` 再次触发 `_just`，在真实 completion context 下将 `=` 作为 suffix 插入 buffer。  
修法：引入 `_ble_registered` 标志，有注册补全函数但 pool 为空时**静默退出**，不 fallback。

**Bug 9 — 循环模式误用旧状态**

原因：循环检查只看 `$LASTWIDGET` 和 `$#_BLE_CANDS`，不验证 buffer 位置。旧 bug 留下 `_BLE_CANDS=("=")` 后，下次 Tab 直接进循环复现旧问题。  
修法：循环条件加 `[[ "$LBUFFER" == "${_BLE_PFX}${_BLE_CANDS[$_BLE_IDX]}" ]]`，buffer 不匹配则视为新一轮补全。

---

### 匹配过于宽松

**Bug 10 — 输入 `picli` 时补全出大量无关候选**

原因：Pass 2c（pure subsequence）生成 `*p*i*c*l*i*`，在几千个命令的 pool 里能命中任意包含这五个字母（按序）的字符串。  
修法：在 `_ble_filter` 所有 pass 运行前加首字母预过滤，pool 收窄到首字母与 `word[1]` 相同的候选：`pool=( ${(M)pool:#${(b)word[1]}*} )`。

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

---

### 历史自动建议

**Bug 14 — 回车后灰色建议残留在终端输出中**

现象：历史记录是 `ls tools`，用户只输入 `ls` 然后回车，终端输出行显示 `ls tools`，但实际执行的是 `ls`。

根因（两层）：
1. `zle-line-finish` 触发时序太晚——ZLE 已完成最终渲染并打印到终端，此时清空 `POSTDISPLAY` 为时已晚。
2. 包装 `accept-line` 清空建议后，若把 `_BLE_SUGGESTION_NEEDLE` 重置为 `""`，随后触发的 `zle-line-pre-redraw` 会判断 `LBUFFER != needle`，重新搜历史，再次把建议写回 `POSTDISPLAY`，前功尽弃。

修法：包装 `accept-line`，清空建议后将 `_BLE_SUGGESTION_NEEDLE` 设为**当前 `$LBUFFER`**：

```zsh
_ble_accept_line() {
    POSTDISPLAY=""
    region_highlight=( ${region_highlight:#*memo=ble-sug} )
    _BLE_SUGGESTION=""
    _BLE_SUGGESTION_NEEDLE="$LBUFFER"   # ← 锁定 needle，阻止 pre-redraw 重新搜历史
    zle .accept-line
}
zle -N accept-line _ble_accept_line
```
