# finsh

> 读作 **"finish"** — `fin`（鱼鳍，致敬 Fish shell）+ `sh`（shell），中间的 `i` 故意省略

Fish shell 带来了一种「所见即所得」的补全体验——候选始终可见，模糊匹配让任意片段都能命中目标。
用过之后再回到 zsh 的 Tab，总觉得少了什么。

[ble.sh](https://github.com/akinomyoga/ble.sh) 证明了在 Bash 里复刻这种体验是可能的。
于是 **finsh** 诞生了——把同样的补全哲学带给 macOS 上的 zsh 用户。

---

## 核心解决的问题

`fzf-tab` 等方案的候选来自 zsh 原生补全——zsh 已用**精确前缀**过滤了一遍：
输入 `piclaud` 想匹配 `pi-claude`，zsh 先把不以 `piclaud` 开头的候选全砍掉，
fzf 拿到的是空列表。

finsh 在 **ZLE 层**自行收集原始候选，完全绕过 zsh 的前缀截断。

---

## 特性

- **两段式补全**：第一次 Tab 展示候选列表（show 模式）；第二次 Tab 填入并循环切换
- **实时重过滤**：show 模式下继续输入，候选列表实时更新，无需重新按 Tab
- **多级 fuzzy 匹配**：前缀 → substring → head-anchored subsequence → pure subsequence
- **历史自动建议**：灰色显示历史匹配后缀，`→` 一键接受
- **路径补全**：含 dotfile，层级 glob，支持 `~` 展开
- **子命令 / 选项补全**：优先用 zsh 注册的补全函数，自动降级到解析 `--help` 输出

---

## 安装

### 手动

```zsh
mkdir -p ~/.zsh/plugins
curl -fsSL https://raw.githubusercontent.com/edhub/finsh/main/finsh.zsh \
    -o ~/.zsh/plugins/finsh.zsh
```

在 `~/.zshrc` 中添加：

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

在 `~/.zshrc` 的 `plugins` 列表中添加 `finsh`：

```zsh
plugins=(... finsh)
```

---

脚本会自动完成初始化：在 macOS 上自动将 Homebrew 补全目录加入 `fpath`，并在需要时运行 `compinit`。

> **诊断**：子命令补全不工作时执行 `print $_comps[git]`。
> 若为空说明 Homebrew 未安装或补全文件缺失（`brew install zsh-completions`）。

---

## 按键

| 按键 | 行为 |
|------|------|
| `Tab`（第 1 次）| fuzzy 过滤 → 底部展示候选列表（show 模式） |
| 继续输入 | 实时重过滤候选列表 |
| `Tab`（第 2 次）| 填入第一候选，进入 cycle 模式 |
| `Tab`（cycle 中）| 循环切换到下一候选 |
| `Shift+Tab` | 原生 zsh 补全（保留上下文感知行为）|
| `→` / `Ctrl+F` | 接受历史自动建议；无建议时退化为 forward-char |
| 任意其他键 | 接受当前候选，列表消失 |

---

## Tab 补全行为

### 第 1 次 Tab — Show 模式

按下 Tab 后立即在底部展示所有候选，命令行内容**不变**，可以继续输入过滤：

```
❯ brew li
list  link  linkage  livecheck
```

继续输入 `nk`：

```
❯ brew link
link  linkage
```

### 第 2 次 Tab — 填入并循环

再按 Tab 填入第一候选，进入 cycle 模式，继续按 Tab 循环切换：

```
❯ brew link
[link]  linkage
```

```
❯ brew linkage
link  [linkage]
```

---

## 匹配优先级

所有 pass 运行前先按首字母预过滤，逐级降级，命中即停止：

| Pass | 名称 | 示例 |
|------|------|------|
| pre | 首字母预过滤 | `pi…` 只在 `p` 开头的候选里跑 |
| 1 | 精确前缀 | `pi` → `pi-claude` |
| 2a | substring | `pi-cl` → `pi-claude` |
| 2b | head-anchored subsequence | `piclaud` → `pi-claude` |
| 2c | pure subsequence | `pclaud` → `pi-claude` |

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

## 文件

| 文件 | 说明 |
|------|------|
| `finsh.zsh` | 唯一实现文件 |
| `DESIGN.md` | 设计文档（架构、实现细节、Bug 历史）|
| `tests/test-help-parser.zsh` | `_finsh_parse_help` 与 `_finsh_filter` 单元测试 |
