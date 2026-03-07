# AGENTS.md — fzf-ble-complete

## 项目概览

一个 zsh ZLE widget，完全绕过 zsh 原生前缀过滤，实现 ble.sh 风格的多级 fuzzy 补全。

> 架构与实现细节见 [DESIGN.md](DESIGN.md)。  
> 安装与用法见 [README.md](README.md)。

---

## 文件结构

```
fzf-ble-complete/
├── fzf-ble-complete.zsh  # 唯一实现文件
├── README.md             # 安装、按键、补全行为
├── DESIGN.md             # 设计文档（架构、实现细节、Bug 历史）
└── AGENTS.md             # 本文件（AI agent 上下文）
```

安装路径（生产环境）：`~/.zsh/plugins/fzf-ble-complete.zsh`

---

## 修改前必读

每条约束都有对应的 Bug 历史，见 [DESIGN.md § Bug 历史](DESIGN.md#bug-历史)。

### compadd hook → [DESIGN.md § compadd hook 与 zle -C](DESIGN.md#compadd-hook-与-zle--c)

- 必须用 `zle -C`，直接 `zle complete-word` 走 C 层，hook 无效
- `_FZF_BLE_POOL` 必须 `typeset -ga`；`_fzf_ble_capture` 必须定义在文件顶层
- 不调用 `builtin compadd`，否则触发 "do you wish to see all N possibilities?"
- 组合 flag（如 `-qS`）须用正则检测含参字符并 `skip_next=1`，否则 suffix 值（如 `=`）被当候选词（Bug 8）

### 路径补全 → [DESIGN.md § 路径补全](DESIGN.md#路径补全)

- `~` 在双引号内不展开，用 `${dir/#\~/$HOME}` 替换（Bug 1）
- glob 须加 `D` qualifier（`*(.DN)` / `*(/DN)`）才能匹配 dotfile（Bug 3）
- 根目录 `xbase=""` 需特判，避免 `//Applications` 双斜杠（Bug 2）

### 循环状态 → [DESIGN.md § 循环模式](DESIGN.md#循环模式)

- 循环条件必须验证 `LBUFFER == _BLE_PFX + _BLE_CANDS[_BLE_IDX]`，否则旧脏状态被误用（Bug 9）

### 静默退出 vs fallback → [DESIGN.md § pool 为空时的回退策略](DESIGN.md#pool-为空时的回退策略)

- 有注册补全函数但 pool 为空 → 静默退出；无注册函数 → fallback `zle complete-word`（Bug 7）

### 历史自动建议 → [DESIGN.md § 历史自动建议](DESIGN.md#历史自动建议)

- 必须包装 `accept-line`，`zle-line-finish` 时序太晚（Bug 14）
- 清空建议后把 `_BLE_SUGGESTION_NEEDLE` 设为 `"$LBUFFER"`（而非 `""`），阻止 pre-redraw 重新搜历史（Bug 14）

### 语法陷阱

- `${${(Az)prefix}[1]}` 取首词，不能写 `${(z)prefix}[1]`（取到首字符，Bug 6）
- `${(Onk)history}` 不加外层引号，不能写 `"${(@On)${(k)history}}"`（把所有 key 当单个元素，Bug 13）
- `local` 声明须放在循环体**外**；循环体内 `typeset` 每次迭代都会把初始化副作用输出到终端（Bug 12）

### `_ble_filter` → [DESIGN.md § 匹配优先级](DESIGN.md#匹配优先级_ble_filter)

- 首字母预过滤不得移除（Bug 10）
- glob 匹配用 `${(b)word}` 转义元字符

---

## 前置依赖

```zsh
fpath=(/opt/homebrew/share/zsh/site-functions $fpath)   # 必须在 compinit 之前
autoload -Uz compinit
compinit -d ~/.zcompdump                                  # 必须在 source 之前，否则 $_comps 为空
source ~/.zsh/plugins/fzf-ble-complete.zsh
```
