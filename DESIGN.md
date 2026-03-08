# fzf-ble-complete — 设计文档

> 安装与快速上手见 [README.md](README.md)。

---

## 补全流程总览

```
Tab 键
 │
 ├─ 第 2 次 Tab：LASTWIDGET==本widget && _BLE_CANDS非空
 │               && LBUFFER==_BLE_PFX+_BLE_CANDS[_BLE_IDX]
 │               → 弹出 fzf inline popup（--height=~10，ayu_light 配色）
 │                 以 _BLE_WORD（原始输入词）作为初始 query
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
           │    │
           │    ├─ pool 非空 → 使用 compadd 结果
           │    │
           │    └─ pool 为空（_arguments 等绕过 function-level compadd）
           │         ↓ 降级到 --help 路径
           │
           └─ pool 为空 → 解析 $cmd [subcmd…] --help（状态机）
                │
                ├─ word 以 - 开头              → 选项池（_BLE_PARSE_OPTS）
                ├─ 有子命令（_BLE_PARSE_SUBCMDS 非空） → 子命令池
                ├─ 无子命令但有选项（如 node）   → 选项池，word 补 "--" 前缀
                └─ pool 仍为空
                     ├─ _ble_registered=1 → 静默退出
                     └─ _ble_registered=0 → fallback zle complete-word
```

---

## 文档目录

| 文档 | 内容 |
|------|------|
| [docs/matching.md](docs/matching.md) | 匹配优先级（Pass 1–2c）、首字母预过滤、路径补全实现细节 |
| [docs/subcommand.md](docs/subcommand.md) | 子命令/选项补全、`--help` 状态机、`compadd` hook 与 `zle -C` |
| [docs/loop-suggestion.md](docs/loop-suggestion.md) | 两段式补全状态管理（内联填入 + fzf popup）、历史自动建议实现 |
| [docs/bugs.md](docs/bugs.md) | 历史 Bug 记录（Bug 1–17） |
