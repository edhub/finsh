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

每条约束都有对应的 Bug 历史，见 [docs/bugs.md](docs/bugs.md)。

### compadd hook → [docs/subcommand.md § compadd hook 与 zle -C](docs/subcommand.md#compadd-hook-与-zle--c)

- 必须用 `zle -C`，直接 `zle complete-word` 走 C 层，hook 无效
- `_FZF_BLE_POOL` 必须 `typeset -ga`；`_fzf_ble_capture` 必须定义在文件顶层
- 不调用 `builtin compadd`，否则触发 "do you wish to see all N possibilities?"
- 组合 flag（如 `-qS`）须用正则检测含参字符并 `skip_next=1`，否则 suffix 值（如 `=`）被当候选词（Bug 8）

### 路径补全 → [docs/matching.md § 路径补全](docs/matching.md#路径补全)

- `~` 在双引号内不展开，用 `${dir/#\~/$HOME}` 替换（Bug 1）
- glob 须加 `D` qualifier（`*(.DN)` / `*(/DN)`）才能匹配 dotfile（Bug 3）
- 根目录 `xbase=""` 需特判，避免 `//Applications` 双斜杠（Bug 2）

### 两段式补全状态 → [docs/loop-suggestion.md § 两段式补全](docs/loop-suggestion.md#两段式补全)

- 第 2 次 Tab 触发条件必须验证 `LBUFFER == _BLE_PFX + _BLE_CANDS[_BLE_IDX]`，否则旧脏状态被误用（Bug 9）
- 状态清零时必须同时清 `_BLE_CANDS / _BLE_IDX / _BLE_PFX / _BLE_WORD`，共四个变量
- `_BLE_WORD` 保存 opts-only 工具下**已加 `--` 前缀的 word**（如 `--bu`），fzf query 直接匹配 `--build` 候选，不能改成存原始词
- `zle -M` 不支持 ANSI 转义码（ESC → `^[` 字面输出），候选列表只能用纯文本

### 静默退出 vs fallback → [docs/subcommand.md § pool 为空时的回退策略](docs/subcommand.md#pool-为空时的回退策略)

- 有注册补全函数但 pool 为空 → **先降级到 `--help` 路径**，help 也无结果才静默退出
- 无注册函数且 help 也无结果 → fallback `zle complete-word`（Bug 7 / Bug 15）
- `_arguments` 类补全函数（如 `_hx`）用 `comparguments` C builtin，**绕过** function-level compadd hook，pool 永远为空，需靠降级路径兜底（Bug 15）

### opts-only 工具路由 → [docs/subcommand.md § 无子命令但有选项时的路由](docs/subcommand.md#无子命令但有选项时的路由opts-only-工具)

- subcmds 为空但 opts 非空时，word 不以 `-` 开头也路由到 opts 池（Bug 16）
- 此时给 `word` 补 `"--"` 前缀：`"bu"` → `"--bu"` → 前缀匹配 `--build-sea`
- `_BLE_PFX` 不变，候选直接替换原始 word

### `zle -M` 消息以 `-` 开头 → [docs/bugs.md § Bug 17](docs/bugs.md#bug-17--node--btabtab-第二次-tab-报错-zle24-bad-option--b)

- `zle -M "msg"` 在消息以 `-` 开头时，`zle` 把消息内容解析为自己的 option，报 `bad option`（Bug 17）
- 规律：**凡是 `zle -M` 的消息内容可能以 `-` 开头，都应写 `zle -M -- "msg"`**

### 逗号列表解析 → [docs/bugs.md § Bug 18](docs/bugs.md#bug-18--cargo-butab-候选里出现-but描述文字里的逗号被误解析为-alias-分隔符)

- 按逗号分割前必须先剥离描述：`_aliases_part="${_trimmed%%  *}"`（Bug 18）
- 否则描述文字里的逗号（如 `errors, but don't...`）会产生 `but` 等干扰词

### opts 正则短选项部分 → [docs/bugs.md § Bug 19](docs/bugs.md#bug-19--wget---notab-漏掉---no-verbose-等选项多字符短选项不匹配)

- 短选项前缀用 `-[a-zA-Z0-9]+`，允许多字符短选项（`-nv,` `-4,` 等）（Bug 19）
- 旧的 `-[a-zA-Z]` 只匹配单字母，导致 wget 等工具丢失多字符短选项对应的 `--long` 选项

### 历史自动建议 → [docs/loop-suggestion.md § 历史自动建议](docs/loop-suggestion.md#历史自动建议)

- 必须包装 `accept-line`，`zle-line-finish` 时序太晚（Bug 14）
- 清空建议后把 `_BLE_SUGGESTION_NEEDLE` 设为 `"$LBUFFER"`（而非 `""`），阻止 pre-redraw 重新搜历史（Bug 14）

### 语法陷阱

- `${${(Az)prefix}[1]}` 取首词，不能写 `${(z)prefix}[1]`（取到首字符，Bug 6）
- `${(Onk)history}` 不加外层引号，不能写 `"${(@On)${(k)history}}"`（把所有 key 当单个元素，Bug 13）
- `local` 声明须放在循环体**外**；循环体内 `typeset` 每次迭代都会把初始化副作用输出到终端（Bug 12）

### `_ble_filter` → [docs/matching.md § 匹配优先级](docs/matching.md#匹配优先级_ble_filter)

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
