# 循环模式与历史自动建议

> 返回 [DESIGN.md](../DESIGN.md)

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
