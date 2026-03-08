# 两段式补全与历史自动建议

> 返回 [DESIGN.md](../DESIGN.md)

---

## 两段式补全

补全状态由四个全局变量维持，跨 widget 调用保持：

```zsh
typeset -ga _BLE_CANDS   # 候选列表
typeset -gi _BLE_IDX=0   # 当前索引（1-based）
typeset -g  _BLE_PFX=""  # 候选前缀（LBUFFER 的不变部分）
typeset -g  _BLE_WORD="" # 用户输入的原始词（fzf popup query 用）
```

### 第 1 次 Tab — 内联填入

`_fzf_ble_complete` 收集候选、过滤，将第一候选写入 `LBUFFER`，
用 `zle -M` 在提示符下方展示候选列表（`[当前项]` 加方括号标记）：

```
[list]  link  linkage  livecheck
```

同时保存 `_BLE_WORD`（用户输入的原始词，如 `li`），供第 2 次 Tab 作为 fzf 初始 query。

### 第 2 次 Tab — fzf Popup

第 2 次 Tab 触发条件（三个都要满足）：

```zsh
[[ "$LASTWIDGET" == "_fzf_ble_complete" ]]                        # 上一个 widget 是本 widget
&& (( $#_BLE_CANDS ))                                             # 有候选
&& [[ "$LBUFFER" == "${_BLE_PFX}${_BLE_CANDS[$_BLE_IDX]}" ]]     # buffer 与上次填入一致
```

第三个条件是关键——防止旧 `_BLE_CANDS` 脏状态被误用（用户可能手动修改了 buffer）。

触发后：

1. 快照 `_BLE_PFX` / `_BLE_CANDS` / `_BLE_WORD` 到局部变量
2. 立即清零全局状态、清除 `zle -M` 消息，避免 fzf 返回后状态污染
3. 启动 fzf（`--height=~10` 内联模式，`--query="$typed"` 预填原始输入词）
4. 用户选择后将 `${pfx}${selected}` 写入 `LBUFFER`；取消则 buffer 不变

```zsh
# fzf 调用核心
selected=$(printf '%s\n' "${cands[@]}" | fzf \
    --height=~10 \
    --layout=reverse \
    --no-sort \              # 保留 _ble_filter 的优先级排序
    --query="$typed" \       # 预填用户原始输入，可继续过滤
    --color='...' \          # ayu_light 配色
    2>/dev/null)
```

`--no-sort` 保留 `_ble_filter` 按 Pass 1→2c 排好的优先级顺序，
不让 fzf 自己重排（fzf 默认按匹配分重排）。

### 状态清理

| 时机 | 操作 |
|------|------|
| 新一轮补全开始（widget 顶部）| 显式清零 `_BLE_CANDS / _BLE_IDX / _BLE_PFX / _BLE_WORD` |
| fzf popup 触发前 | 同上（快照后立即清零） |
| 其他键触发 `zle-line-pre-redraw` | 检测到 `$LASTWIDGET ≠ _fzf_ble_complete` 时清零并调 `zle -M ""` |

> ⚠️ **修改注意**
> - 第 2 次 Tab 的触发条件三个都要满足，缺少 buffer 验证会导致脏状态被误用（Bug 9）
> - `_BLE_WORD` 保存的是 opts-only 工具场景下**已经加了 `--` 前缀的 word**（如用户输入 `bu`，`_BLE_WORD` 为 `--bu`），这样 fzf query 能直接匹配 `--build` 候选，是正确行为
> - `zle -M` 不支持 ANSI 转义码（ESC 会被显示为 `^[`），候选列表只能用纯文本 + `[方括号]` 标记

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

### 与补全共存

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
