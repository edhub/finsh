# finsh — Design Document

> For installation and quick start, see [README.md](README.md).

> 中文文档：[DESIGN.zh.md](DESIGN.zh.md)

---

## Completion Flow Overview

```
Tab key
 │
 ├─ 2nd Tab: LASTWIDGET==this_widget && _FINSH_CANDS non-empty
 │           && LBUFFER==_FINSH_PFX+_FINSH_CANDS[_FINSH_IDX]
 │           → launch fzf inline popup (--height=~10, ayu_light theme)
 │             using _FINSH_WORD (original typed word) as initial query
 │
 └─ New completion round
      │
      ├─ word contains / → path completion (glob + dotfiles)
      │
      ├─ prefix is all whitespace → command name completion
      │                             (commands/functions/aliases/builtins)
      │
      └─ subcommand/option completion
           │
           ├─ _comps[$cmd] non-empty → zle -C capture (hook compadd to collect candidates)
           │    │
           │    ├─ pool non-empty → use compadd results
           │    │
           │    └─ pool empty (_arguments etc. bypass function-level compadd)
           │         ↓ fall back to --help path
           │
           └─ pool empty → parse $cmd [subcmd…] --help (state machine)
                │
                ├─ word starts with -              → options pool (_FINSH_PARSE_OPTS)
                ├─ has subcommands (_FINSH_PARSE_SUBCMDS non-empty) → subcmds pool
                ├─ no subcommands but has options (e.g. node) → options pool, prepend "--" to word
                └─ pool still empty
                     ├─ _ble_registered=1 → silently exit
                     └─ _ble_registered=0 → fallback zle complete-word
```

---

## Documentation Index

| Document | Contents |
|----------|----------|
| [docs/matching.md](docs/matching.md) | Match priority (Pass 1–2c), first-letter pre-filter, path completion implementation |
| [docs/subcommand.md](docs/subcommand.md) | Subcommand/option completion, `--help` state machine, `compadd` hook and `zle -C` |
| [docs/loop-suggestion.md](docs/loop-suggestion.md) | Two-phase completion state management (inline fill + fzf popup), history autosuggestion |
| [docs/bugs.md](docs/bugs.md) | Historical bug records (Bug 1–20) |
