# Bug 历史

> 返回 [DESIGN.md](../DESIGN.md)

---

## 路径补全

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

## help 解析

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

## 语言 / 语法陷阱

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

## compadd hook 解析

**Bug 8 — `just <tab>` 无 justfile 时补全到 `=`（根本原因）**

原因：`_describe` 传给 `compadd` 的是组合 flag `-qS`（不是 `-q -S`）。hook 里 `-qS` 匹配 `-*` 分支被忽略，下一个参数 `=`（suffix 值）没被跳过，直接当候选词进了 pool，最终 pool=`("=")` → 唯一候选直接补全。  
修法：`-*` 分支加检测，若组合 flag 中含有带参字符（`[PSpsWdJVXxrRMFtoEIi]`）则 `skip_next=1`。

---

## 循环状态

**Bug 7 — `just <tab>` 无 justfile 时补全到 `=`（表象）**

原因：`_comps[just]=_just`，zle-C capture 运行，pool 为空，fallback `zle complete-word` 再次触发 `_just`，在真实 completion context 下将 `=` 作为 suffix 插入 buffer。  
修法：引入 `_ble_registered` 标志，有注册补全函数但 pool 为空时**静默退出**，不 fallback。

**Bug 9 — 循环模式误用旧状态**

原因：循环检查只看 `$LASTWIDGET` 和 `$#_BLE_CANDS`，不验证 buffer 位置。旧 bug 留下 `_BLE_CANDS=("=")` 后，下次 Tab 直接进循环复现旧问题。  
修法：循环条件加 `[[ "$LBUFFER" == "${_BLE_PFX}${_BLE_CANDS[$_BLE_IDX]}" ]]`，buffer 不匹配则视为新一轮补全。

---

## 匹配过于宽松

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

## 历史自动建议

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

---

## `_arguments` 绕过 compadd hook / opts-only 工具

**Bug 15 — `hx <Tab>` 无补全（`_arguments` 绕过 function-level compadd）**

现象：`hx` 有注册补全函数 `_hx`，但 `hx <Tab>` 什么都不显示。

根因：`_hx` 使用 `_arguments -C`，其底层 `comparguments` 是 C builtin，**完全绕过** function-level `compadd` hook。`_FZF_BLE_POOL` 永远为空，`_ble_registered=1` 且 pool 为空 → 静默退出。

```
zle -C → _fzf_ble_capture → function compadd() { ... } → _main_complete
                                                          → _hx
                                                          → _arguments -C
                                                          → comparguments (C builtin)
                                                             ← 不经过 function compadd ✗
```

修法：将 `--help` 解析从 `else` 分支提出，改为 `if (( $#pool == 0 )) && ...`，使有注册函数但 hook 为空时也走 `--help` 路径：

```zsh
if [[ -n "${_comps[$_ble_cmd]-}" ]]; then
    _ble_registered=1
    # ... zle -C capture ...
    pool=( "${_FZF_BLE_POOL[@]}" )
fi
# compadd 未能捕获 或 无注册函数 → 降级到 --help
if (( $#pool == 0 )) && [[ -n "$_ble_cmd" ]]; then
    # ... --help 解析 ...
fi
```

**Bug 16 — `node bu<Tab>` 无补全（opts-only 工具路由错误）**

现象：`node --help` 有 181 个选项，但 `node bu<Tab>` 什么都不补全。

根因：`word = "bu"` 不以 `-` 开头 → 路由到 `_BLE_PARSE_SUBCMDS` pool → node 无子命令 → pool 为空 → fallback 文件补全 → 无匹配。

修法：subcmds 为空但 opts 非空时，把 opts 纳入 pool，并给 `word` 补 `--` 前缀：
- `"bu"` → `"--bu"` → 前缀匹配 `--build-sea`、`--build-snapshot`、`--build-snapshot-config`
- `_BLE_PFX` 仍为 `"node "`，候选直接替换原始 `"bu"`，LBUFFER 变为 `"node --build-sea"`

**Bug 17 — `node -b<Tab><Tab>` 第二次 Tab 报错 `zle:24: bad option: -b`**

现象：第一次 Tab 正常（LBUFFER → `node --build-sea`），第二次 Tab 报错 `_ble_show_candidates:zle:24: bad option: -b`。

根因：`_ble_show_candidates` 最后一行是 `zle -M "${(j:\n:)out}"`。候选列表格式化后第一行形如 `"--build-sea  [--build-snapshot]  ..."` 以 `-` 开头。`zle` 的选项解析器把这个字符串解析为选项，其中 `-b` 被识别为 "bad option"。

```zsh
# 出错：zle 把 "--build-sea ..." 里的 -b 当成 zle 自己的选项
zle -M "--build-sea  [--build-snapshot]  ..."
#        ↑ 以 - 开头，被解析为选项

# 修法：用 -- 终止 option 解析
zle -M -- "--build-sea  [--build-snapshot]  ..."
#     ↑↑ -- 之后均视为位置参数
```

修法：`zle -M` 改为 `zle -M -- "..."` 即可。规律：**凡是 `zle -M` 的消息内容可能以 `-` 开头，都应加 `--`**。
