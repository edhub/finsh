# fzf-ble-complete

ble.sh 风格的多级 fuzzy 补全 widget，绑定到 Tab 键。

**解决的核心问题**：fzf-tab 在收到候选之前，zsh 已用前缀过滤截断了列表，
导致 `piclaud` 无法匹配 `pi-claude`。本项目在 ZLE 层完全自行收集候选，绕过 zsh 过滤。

---

## 安装

```zsh
# ~/.zshrc —— 顺序不能颠倒
fpath=(/opt/homebrew/share/zsh/site-functions $fpath)   # homebrew 补全（_docker、_gh、_just …）
autoload -Uz compinit
compinit -d ~/.zcompdump

source ~/.zsh/plugins/fzf-ble-complete.zsh
```

> **诊断**：子命令补全不工作时执行 `print $_comps[git]`。
> 若为空说明 `compinit` 未运行或 fpath 未包含对应补全文件。

---

## 按键

| 按键 | 行为 |
|------|------|
| `Tab`（第 1 次）| fuzzy 过滤 → 内联填入第一候选，底部展示候选列表 |
| `Tab`（第 2 次）| 弹出 fzf inline popup，交互选择 |
| `Shift+Tab` | 原生 zsh 补全（保留上下文感知行为）|
| `→` | 接受历史自动建议；无建议时退化为 forward-char |
| 任意其他键 | 接受当前候选，列表消失 |

---

## 两段式补全

### 第 1 次 Tab — 内联预览

按下 Tab 后立即将最佳匹配填入命令行，同时在底部展示所有候选：

```
❯ brew li
[list]  link  linkage  livecheck
```

`[list]` 是当前内联填入的候选，直接敲其他键即可接受并继续输入。

### 第 2 次 Tab — fzf Popup

再次按 Tab 弹出 fzf inline popup，可视化交互选择：

```
❯ brew li
  link
  linkage
> list
  livecheck
  4/4 ──────
> li
```

- 已预填第 1 次 Tab 时的输入词作为初始 query，可继续输入过滤
- `Enter` 确认，`Esc` / `Ctrl-C` 取消（buffer 不变）
- fzf 所有标准按键均可用（`Ctrl-P/N`、`Ctrl-J/K` 等）

> **依赖**：fzf >= 0.35.0（`--height=~N` 语法需要此版本）

### 配色

Popup 内置 ayu_light 配色。如需替换，在 `~/.zshrc` 中通过 `FZF_DEFAULT_OPTS` 覆盖，
或 fork 后修改 `_fzf_ble_complete` 中的 `--color` 参数。

---

## 补全场景

| 场景 | 候选来源 |
|------|----------|
| 第一个词（命令名）| `commands` + 可见函数 + aliases + builtins |
| 含 `/` 的词（路径）| 对应目录层 glob（含 dotfile），仅取 basename 过滤 |
| 有注册补全函数的子命令/选项 | `zle -C` + `compadd` hook 截获 zsh 原生补全 |
| 无注册补全函数的子命令/选项 | 解析 `$cmd [subcmd…] --help` 输出 |
| 以上均无结果 | 无注册补全函数时回退 `zle complete-word`；有注册函数时静默退出 |

---

## 匹配优先级

所有 pass 运行前先按首字母预过滤，逐级降级，命中即停止。详见 [DESIGN.md § 匹配优先级](DESIGN.md#匹配优先级_ble_filter)。

| Pass | 名称 | 示例 |
|------|------|------|
| pre | 首字母预过滤 | `pi…` 只在 `p` 开头的候选里跑 |
| 1 | 精确前缀 | `pi` → `pi-claude` |
| 2a | substring | `pi-cl` → `pi-claude` |
| 2b | head-anchored subsequence | `piclaud` → `pi-claude` |
| 2c | pure subsequence | `pclaud` → `pi-claude` |

---

## 文件

| 文件 | 说明 |
|------|------|
| `fzf-ble-complete.zsh` | 唯一实现文件 |
| `DESIGN.md` | 设计文档（架构、实现细节、Bug 历史）|
| `AGENTS.md` | AI agent 上下文（约束清单、快速参考）|
| `tests/test-help-parser.zsh` | `_ble_parse_help` 与 `_ble_filter` 单元测试 |
