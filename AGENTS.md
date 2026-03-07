# AGENTS.md — fzf-ble-complete

## 项目概览

一个 zsh ZLE widget，完全绕过 zsh 原生前缀过滤，实现 ble.sh 风格的多级 fuzzy 补全。

> 架构与设计细节见 [zsh-fuzzy-completion.md](zsh-fuzzy-completion.md)。  
> 安装与用法见 [README.md](README.md)。

---

## 文件结构

```
fzf-ble-complete/
├── fzf-ble-complete.zsh      # 唯一实现文件
├── README.md                 # 安装、按键、补全行为
├── zsh-fuzzy-completion.md   # 完整设计文档（架构、实现细节、Bug 历史）
└── AGENTS.md                 # 本文件（AI agent 上下文）
```

安装路径（生产环境）：`~/.zsh/plugins/fzf-ble-complete.zsh`

---

## 关键约束与坑点

修改代码前必读，这里记录的都是踩过的真实坑。

### `compadd` hook

- **必须用 `zle -C`**：直接调 `zle complete-word` 走 C 层，hook 无效
- **`_FZF_BLE_POOL` 必须 `typeset -ga`**：completion context 内访问不到外层 local 变量
- **`_fzf_ble_capture` 定义在文件顶层**：不能嵌套在函数内部
- **不调用 `builtin compadd`**：否则退出时 zsh 触发 "do you wish to see all N possibilities?"
- **组合 flag 处理**：`_describe` 会传 `-qS`（不是 `-q -S`），`-*` 分支须检测是否含带参字符
  并 `skip_next=1`，否则 suffix 值（如 `=`）会被当候选词

```zsh
# 关键：-* 分支
-*)  [[ "${@[i]}" =~ '[PSpsWdJVXxrRMFtoEIi]' ]] && skip_next=1 ;;
```

### 路径补全

- `~` 在双引号内不展开 → 用 `${dir/#\~/$HOME}` 替换
- glob `*` 不匹配 dotfile → qualifier 加 `D`（`*(.DN)` / `*(/DN)`）
- 根目录 `xbase=""` 需特判 → 用 `/*(.DN) /*(/DN)` 避免 `//` 双斜杠

### 循环状态

- 循环条件须验证 `LBUFFER == _BLE_PFX + _BLE_CANDS[_BLE_IDX]`
- 旧 bug 可能留下脏 `_BLE_CANDS`，不验证 buffer 会复现旧问题

### `_ble_registered` 标志

- 有注册补全函数（`_comps[$cmd]` 非空）时设为 1
- pool 为空时：`_ble_registered=1` → 静默退出；`=0` → fallback `zle complete-word`
- 避免 `_just` 等在无 justfile 时因二次触发产生 `=` 等噪声

### `print -l --`

- 候选词可能以 `--` 开头（如 `--release`）
- `print -l "--release"` 会把 `--release` 解析为 flag → 报错
- 所有 `print -l` 一律加 `--`：`print -l -- "${array[@]}"`

### `${(Az)prefix}[1]` 取首词

- `${(z)prefix}` 返回数组，但若写 `${(z)prefix}[1]` 取的是字符串第一个**字符**
- 正确写法：`${${(Az)prefix}[1]}`，`(A)` 强制为数组后再取 `[1]`

---

## 修改注意事项

- **`_ble_filter`**：结果写入全局 `_BLE_FILTERED`（不开 subshell），glob 匹配中用 `${(b)word}` 转义元字符，任何修改都要保持一致；word 为空时 `_BLE_FILTERED` 置空，调用方直接用原始 pool；**所有 pass 前都有首字母预过滤**（`pool=( ${(M)pool:#${(b)word[1]}*} )`），不得移除，否则 Pass 2c 的纯 subsequence 会在大型候选池中命中大量无关条目
- **`_BLE_HELP_CACHE`**：`typeset -gA`，key=命令词空格拼接，同一 session 只 fork 一次；修改 help 解析逻辑后注意缓存 key 的一致性
- **`compadd` 参数解析**：`-[ODA]` 整个调用跳过；`-a`/`-k` 展开数组/哈希键；
  单独带参 flag 用精确匹配；组合 flag 用正则检测含参字符
- **`_ble_show_candidates`**：用 `zle -M` 展示，`${#item} + 2` 做换行宽度预估
- **循环状态生命周期**：widget 顶部显式清零（新一轮），`zle-line-pre-redraw` 检测
  `$LASTWIDGET` 变化后清零（其他键介入）

---

## 前置依赖

```zsh
fpath=(/opt/homebrew/share/zsh/site-functions $fpath)
autoload -Uz compinit
compinit -d ~/.zcompdump
source ~/.zsh/plugins/fzf-ble-complete.zsh
```

- `fpath` 须在 `compinit` **之前**设置
- `compinit` 须在 `source` **之前**运行，否则 `$_comps` 为空
