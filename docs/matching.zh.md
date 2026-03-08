> English documentation: [matching.md](matching.md)

# 匹配优先级与路径补全

> 返回 [DESIGN.zh.md](../DESIGN.zh.md)

---

## 匹配优先级（`_finsh_filter`）

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
> - 结果写入全局 `_FINSH_FILTERED`（不开 subshell），glob 匹配中用 `${(b)word}` 转义元字符，任何修改都要保持一致
> - word 为空时 `_FINSH_FILTERED` 置空，调用方直接用原始 pool
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
