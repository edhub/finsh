# ─────────────────────────────────────────────────────────────────────────────
# fzf-ble-complete.zsh
# ble.sh 风格的多级 fuzzy 补全 widget，绑定到 Tab 键
#
# 匹配优先级（逐级降级，命中即停止）：
#   Pass 1  – 精确前缀              "pi"      → pi-claude
#   Pass 2a – substring             "claude"  → pi-claude
#   Pass 2b – head-anchored subseq  "piclaud" → pi-claude  (p 锚定，iclaud ⊆ i-claude)
#   Pass 2c – pure subsequence      "pclaud"  → pi-claude  (*p*c*l*a*u*d*)
#
# 补全行为：
#   首次 Tab  – fuzzy 过滤 → 内联填入第一个候选，zle -M 展示候选列表
#   再次 Tab  – 循环到下一个候选（$LASTWIDGET 判断是否连续按 Tab）
#   Shift+Tab – 原生 zsh 补全（保留上下文感知行为）
#   其他按键  – 自动接受当前候选，列表消失
#
# 补全场景：
#   命令名   – 从 commands / functions / aliases / builtins 收集
#   子命令   – 有注册补全函数时用 zle -C 建立正规 completion context，hook compadd 截获
#            – 无注册补全函数时尝试 $cmd --list（cargo / helm / kubectl 等）
#   路径     – glob 当前目录层，按文件名部分过滤
# ─────────────────────────────────────────────────────────────────────────────

# compadd hook 的全局暂存区
# （completion context 内调用的函数无法访问外层 widget 的 local 变量）
typeset -ga _FZF_BLE_POOL

# 循环补全状态（跨 widget 调用保持，由 $LASTWIDGET 判断是否延续）
typeset -ga _BLE_CANDS   # 当前循环的候选列表
typeset -gi _BLE_IDX=0   # 当前选中索引（1-based）
typeset -g  _BLE_PFX=""  # 候选词之前的内容（LBUFFER 前缀）

# _ble_filter 的输出数组（避免 subshell，直接在全局数组中写结果）
typeset -ga _BLE_FILTERED

# --help 输出缓存（key=命令路径拼接，value=help 文本；同一 session 只解析一次）
typeset -gA _BLE_HELP_CACHE

# _ble_parse_help 的输出数组（避免 subshell）
typeset -ga _BLE_PARSE_SUBCMDS   # 解析出的子命令列表
typeset -ga _BLE_PARSE_OPTS      # 解析出的 --flag 列表

# 历史自动建议状态
typeset -g _BLE_SUGGESTION=""         # 当前建议后缀（POSTDISPLAY 内容）
typeset -g _BLE_SUGGESTION_NEEDLE=""  # 上次搜索的 needle（避免重复搜索）

# ── --help 输出解析 ────────────────────────────────────────────────────────────
# 输入：$1 = --help 的原始输出文本
# 输出：结果写入全局数组 _BLE_PARSE_SUBCMDS（子命令）和 _BLE_PARSE_OPTS（--flag 选项）
#
# 解析策略：单次扫描状态机，先分类后提取。
#
#   初始状态：flat（启发式，适用于无 section 的工具，如 git）
#
#   遇到以下 section header（行长 ≤ 40 chars、首字母开头）时切换状态：
#     *commands* / *subcommands* → subcmds（提取缩进子命令）
#     *options*  / *flags*       → opts   （提取 --flag）
#     纯大写 USAGE: / ARGS: 等    → other  （整段跳过）
#
#   行长上限 40 用于过滤掉长描述句（如 git 的
#   "These are common Git commands used in various situations:"），
#   避免把句子里的 "commands" 当成 section header 处罚。
#
#   各状态提取规则：
#     subcmds – 1-8 空格缩进 + 小写首词（section 限定，不需要额外启发）
#               逗号列表（npm/cargo 的 "build, b  compile" 风格）同样支持
#     opts    – --flag 行（带或不带 -x, 前缀）
#     other   – 跳过全部行
#     flat    – 同时提取 --flag 和子命令
#               子命令要求 2-8 空格缩进 + 名称后 2+ 空格间距，
#               过滤 "  hx [FLAGS]..." 类 USAGE 行（名称后只有 1 空格）
#
#   已验证工具：
#     section-based: zig(2sp)  cargo(4sp,comma)  npm(comma)
#                    docker(multi-section)  hx(FLAGS:/USAGE:)
#     flat:          git(3sp, 无 section header)
_ble_parse_help() {
    emulate -L zsh
    setopt extendedglob
    local _help_out="$1"
    _BLE_PARSE_SUBCMDS=()
    _BLE_PARSE_OPTS=()
    [[ -z "$_help_out" ]] && return

    local _section="flat"
    local _line _lc _part
    while IFS= read -r _line; do

        # ── Section header detection ─────────────────────────────────────────
        # 条件：行长 ≤ 40（过滤长句）且首字符为字母
        if (( ${#_line} <= 40 )) && [[ "$_line" =~ '^[[:alpha:]]' ]]; then
            _lc="${_line:l}"   # 转小写，实现大小写无关匹配
            if   [[ "$_lc" =~ '(sub)?commands?[[:space:]]*:' ]]; then
                _section="subcmds"; continue
            elif [[ "$_lc" =~ '(options?|flags?)[[:space:]]*:' ]]; then
                _section="opts";    continue
            elif [[ "$_line" =~ '^[A-Z][A-Z -]*:' ]]; then
                # 纯大写 header（USAGE: ARGS: EXAMPLES: 等）
                _section="other";   continue
            fi
        fi

        # ── Per-section extraction ───────────────────────────────────────────
        case "$_section" in

        subcmds)
            # 逗号列表（npm/cargo 风格："  build, b  Compile..."）
            if [[ "$_line" =~ '^[[:space:]]{1,8}[a-z][-a-z0-9]*,' ]]; then
                # 先剥离描述（aliases 与描述之间有 2+ 空格间距），再按逗号分割；
                # 避免描述文字中的逗号被误当成 alias 分隔符
                # 例：`    check, c    Analyze...errors, but don't...` → 只取 `check, c`
                local _trimmed="${_line##[[:space:]]#}"
                local _aliases_part="${_trimmed%%  *}"
                for _part in "${(s:,:)_aliases_part[@]}"; do
                    _part="${_part##[[:space:]]#}"
                    _part="${_part%%[[:space:]]*}"
                    [[ "$_part" =~ '^[a-z][-a-z0-9]*$' ]] && _BLE_PARSE_SUBCMDS+=("$_part")
                done
            # 普通行：1-8 空格缩进 + 小写首词（section 已限定范围，规则简单）
            elif [[ "$_line" =~ '^[[:space:]]{1,8}([a-z][-a-z0-9]*)' ]]; then
                _BLE_PARSE_SUBCMDS+=("$match[1]")
            fi
            ;;

        opts)
            # --flag 行，带或不带 -x, 前缀
            if [[ "$_line" =~ '^[[:space:]]+((-[a-zA-Z0-9]+,?[[:space:]]+)?)(--([a-zA-Z][a-zA-Z0-9-]*))' ]]; then
                _BLE_PARSE_OPTS+=("--$match[4]")
            fi
            ;;

        other) ;;   # USAGE: / ARGS: 等无关 section，整段跳过

        flat)
            # 启发式解析（无 section 工具，如 git）
            # --flag 行
            if [[ "$_line" =~ '^[[:space:]]+((-[a-zA-Z0-9]+,?[[:space:]]+)?)(--([a-zA-Z][a-zA-Z0-9-]*))' ]]; then
                _BLE_PARSE_OPTS+=("--$match[4]")
            # 逗号列表
            elif [[ "$_line" =~ '^[[:space:]]{2,8}[a-z][-a-z0-9]*,' ]]; then
                local _trimmed="${_line##[[:space:]]#}"
                local _aliases_part="${_trimmed%%  *}"
                for _part in "${(s:,:)_aliases_part[@]}"; do
                    _part="${_part##[[:space:]]#}"
                    _part="${_part%%[[:space:]]*}"
                    [[ "$_part" =~ '^[a-z][-a-z0-9]*$' ]] && _BLE_PARSE_SUBCMDS+=("$_part")
                done
            # 普通行：2-8 空格缩进 + 名称后 2+ 空格间距
            # 2+ 空格间距用于排除 "  cmd [ARG]..." 类 USAGE 行（名称后只有 1 空格）
            elif [[ "$_line" =~ '^[[:space:]]{2,8}([a-z][-a-z0-9]*)[^[:space:]]*[[:space:]]{2,}' ]]; then
                _BLE_PARSE_SUBCMDS+=("$match[1]")
            fi
            ;;

        esac
    done <<< "$_help_out"
}

# ── 多级过滤函数 ──────────────────────────────────────────────────────────────
# 结果写入全局 _BLE_FILTERED，避免 $(...) subshell 开销。
# word 为空时 _BLE_FILTERED 置空，调用方应直接使用原始 pool。
_ble_filter() {
    emulate -L zsh
    local word="$1"; shift
    local -a pool=("$@")
    _BLE_FILTERED=()

    [[ -z "$word" ]] && return

    # 首字母预过滤：所有 pass 都要求候选首字母与 word[1] 相同
    # 避免纯 subsequence 命中大量不相关候选（如 *p*i*c*l*i* 匹配整个命令池）
    pool=( ${(M)pool:#${(b)word[1]}*} )
    (( $#pool )) || return

    local w="${(b)word}"   # 转义 glob 元字符，做字面匹配
    local -a r

    # Pass 1 ── 精确前缀
    r=( ${(M)pool:#${~w}*} )
    if (( $#r )); then _BLE_FILTERED=( "${r[@]}" ); return; fi

    # Pass 2a ── substring
    r=( ${(M)pool:#*${~w}*} )
    if (( $#r )); then _BLE_FILTERED=( "${r[@]}" ); return; fi

    # Pass 2b ── head-anchored subsequence（首字母字面匹配，其余 subsequence）
    local tail="*" i
    for (( i = 2; i <= $#word; i++ )); do tail+="${(b)word[i]}*"; done
    r=()
    local c
    for c in "${pool[@]}"; do
        [[ "${c[1]}" == "${word[1]}" ]] || continue
        [[ "${c[2,-1]}" == ${~tail}  ]] && r+=("$c")
    done
    if (( $#r )); then _BLE_FILTERED=( "${r[@]}" ); return; fi

    # Pass 2c ── pure subsequence
    local seq="*"
    for (( i = 1; i <= $#word; i++ )); do seq+="${(b)word[i]}*"; done
    _BLE_FILTERED=( ${(M)pool:#${~seq}} )
}

# ── 候选列表展示 ──────────────────────────────────────────────────────────────
# 用 zle -M 在提示符下方展示所有候选；当前项用 [方括号] 标记。
# 超过终端宽度时自动换行。
_ble_show_candidates() {
    emulate -L zsh
    local cols=${COLUMNS:-80}
    local -a out=()
    local line="" i item

    for (( i = 1; i <= $#_BLE_CANDS; i++ )); do
        if (( i == _BLE_IDX )); then
            item="[${_BLE_CANDS[$i]}]"
        else
            item="${_BLE_CANDS[$i]}"
        fi

        if [[ -z "$line" ]]; then
            line="$item"
        elif (( ${#line} + ${#item} + 2 > cols )); then
            out+=("$line")
            line="$item"
        else
            line+="  $item"
        fi
    done
    [[ -n "$line" ]] && out+=("$line")

    zle -M -- "${(j:\n:)out}"
}

# ── compadd 捕获实现 ───────────────────────────────────────────────────────────
# 必须定义在顶层（全局），供 zle -C 创建的 completion widget 调用。
#
# 关键：compadd 只有在 zle -C 建立的 completion context 内才能被函数覆盖；
# 从普通 widget 直接调 `zle complete-word` 时，补全系统走 C 层，跳过函数查找。
_fzf_ble_capture() {
    emulate -L zsh
    # 在 completion context 内覆盖 compadd，捕获候选词到全局暂存区
    # 注意：不调用 builtin compadd，避免候选写入 zsh completion buffer，
    # 否则 completion context 退出后 zsh 会触发 "do you wish to see all N possibilities?" 提示。
    # 始终 return 0（模拟成功），防止补全函数走 fallback 分支漏掉候选。
    function compadd() {
        local i=1 skip_next=0
        while (( i <= $# )); do
            if (( skip_next )); then skip_next=0; (( i++ )); continue; fi
            case "${@[i]}" in
                # -O/-D/-A 是内部数组操作，跳过整个调用
                -[ODA]) return 0 ;;
                # -a/-k：展开数组/哈希键
                -a)  (( i++ )); [[ -n "${@[i]}" ]] && _FZF_BLE_POOL+=( "${(@P)${@[i]}}" ) ;;
                -k)  (( i++ )); [[ -n "${@[i]}" ]] && _FZF_BLE_POOL+=( "${(kP)${@[i]}}" ) ;;
                # 带一个参数的 flag，跳过 flag+arg
                # 对照 zsh manual compadd：-P -S -p -s -W -d -J -V -X -x -r -R -M -F -E -I -i
                # 额外保留 -t -o（非标准但出现过），false positive 无害
                -[PSpsWdJVXxrRMFtoEIi]) skip_next=1 ;;
                # -- 之后全是候选词
                --)  (( i++ )); _FZF_BLE_POOL+=( "${@[$i,-1]}" ); return 0 ;;
                # 其他 flag（含组合 flag 如 -qS、-ld、-QS 等）
                # 若其中含有需要跳过下一参数的字符，则 skip_next
                -*)  [[ "${@[i]}" =~ '[PSpsWdJVXxrRMFtoEIi]' ]] && skip_next=1 ;;
                # 实际候选词
                *)   _FZF_BLE_POOL+=( "${@[i]}" ) ;;
            esac
            (( i++ ))
        done
        return 0
    }

    # 按优先级触发补全
    if   (( ${+functions[_main_complete]} )); then _main_complete
    elif (( ${+functions[_complete]}      )); then _complete
    else
        # 直接调用命令的补全函数（绕过 dispatcher）
        local _cmd="${words[1]-}" _cfunc="${_comps[${words[1]-}]-}"
        [[ -n "$_cfunc" ]] && "$_cfunc"
    fi
    # unfunction compadd 由 widget 的 always 块统一负责，此处无需重复
}

# ── ZLE widget ────────────────────────────────────────────────────────────────
_fzf_ble_complete() {
    emulate -L zsh
    setopt extendedglob nullglob

    # ── 循环模式：Tab 连按时在候选间切换 ────────────────────────────────────
    if [[ "$LASTWIDGET" == "_fzf_ble_complete" ]] && (( $#_BLE_CANDS )) \
        && [[ "$LBUFFER" == "${_BLE_PFX}${_BLE_CANDS[$_BLE_IDX]}" ]]; then
        _BLE_IDX=$(( (_BLE_IDX % $#_BLE_CANDS) + 1 ))
        LBUFFER="${_BLE_PFX}${_BLE_CANDS[$_BLE_IDX]}"
        _ble_show_candidates
        return
    fi

    # ── 新一轮补全：重置循环状态 ─────────────────────────────────────────────
    _BLE_CANDS=()
    _BLE_IDX=0
    _BLE_PFX=""

    # 光标不在行尾时回退原生补全
    (( CURSOR != ${#LBUFFER} )) && { zle complete-word; return }

    local lbuf=$LBUFFER
    local word prefix

    # 尾部空白 → 光标在新词起始位置，当前词为空
    if [[ "$lbuf" =~ '[[:space:]]$' ]] || [[ -z "$lbuf" ]]; then
        word=""; prefix="$lbuf"
    else
        local words=(${(z)lbuf})
        word="${words[-1]:-''}"
        prefix="${lbuf%${word}}"
    fi

    # ── 路径补全 ──────────────────────────────────────────────────────────────
    if [[ "$word" == */* ]]; then
        local dir base
        if [[ "$word" == */ ]]; then
            # 末尾 / 代表用户明确要补全目录内容（如 ls ~/dev/）
            # 不能用 :h/:t —— ~/dev/:h="~", :t="dev"，会丢掉目录层级
            dir="${word%/}"   # 去掉尾 /，保留完整目录路径
            base=""
        else
            dir="${word:h}"
            base="${word:t}"
        fi
        # base 不足 2 个字符时不触发（含 trailing-slash 的 base="" 情况）
        (( ${#base} >= 2 )) || return
        local xdir="${dir/#\~/$HOME}"   # 展开 ~ （双引号内 ~ 不展开，替换前缀）
        local sep="${dir%/}/"           # 规范化分隔符：去掉末尾 / 再加回，避免 dir="/" 时双斜杠
        local xbase="${xdir%/}"         # 去掉末尾 /，防止 "/" → "//" 路径拼接问题
        local -a names
        if [[ -z "$xbase" ]]; then
            names=( /*(.DN) /*(/DN) )     # 根目录：直接 glob，结果为 /Applications 等
        else
            names=( "${xbase}"/*(.DN) "${xbase}"/*(/DN) )
        fi
        names=( "${names[@]#${xbase}/}" )  # 剥离目录前缀，只保留文件名

        if (( $#names == 0 )); then zle complete-word; return; fi

        _ble_filter "$base" "${names[@]}"
        # base 为空（word="dir/"）时展示目录下全部文件；有 base 但无匹配则展示全部（路径 pool 通常很小）
        local -a show
        if (( $#_BLE_FILTERED )); then
            show=("${_BLE_FILTERED[@]}")
        else
            show=("${names[@]}")
        fi

        if (( $#show == 1 )); then
            LBUFFER="${prefix}${sep}${show[1]}"
            zle reset-prompt
            return
        fi

        _BLE_CANDS=( "${show[@]}" )
        _BLE_PFX="${prefix}${sep}"
        _BLE_IDX=1
        LBUFFER="${_BLE_PFX}${_BLE_CANDS[1]}"
        _ble_show_candidates
        return
    fi

    # 命令名 / 子命令 / 选项补全：word 不足 2 个字符时不触发
    (( ${#word} >= 2 )) || return

    local -a pool=()
    local _ble_registered=0   # 标记是否有注册补全函数（影响 pool 空时的回退策略）
    # ── 命令名补全 ────────────────────────────────────────────────────────────
    if [[ "$prefix" =~ '^[[:space:]]*$' ]]; then
        pool=(
            ${(k)commands}
            ${(k)functions[(I)[^_]*]}
            ${(k)aliases}
            ${(k)builtins}
        )

    # ── 子命令 / 选项补全 ─────────────────────────────────────────────────────
    else
        local _ble_cmd="${${(Az)prefix}[1]-}"

        if [[ -n "${_comps[$_ble_cmd]-}" ]]; then
            # ── 有注册补全函数：走 zle -C 捕获路径 ──────────────────────────
            _ble_registered=1
            # 用 zle -C 建立正规 completion context，在此 context 内 compadd 可被函数覆盖
            _FZF_BLE_POOL=()
            zle -C _fzf_ble_cap complete-word _fzf_ble_capture
            local slbuf=$LBUFFER srbuf=$RBUFFER
            {
                # 移除当前词，让 zsh 以空词在上下文中生成完整候选
                LBUFFER="$prefix"
                RBUFFER=""
                CURSOR=${#LBUFFER}
                zle _fzf_ble_cap 2>/dev/null
            } always {
                LBUFFER="$slbuf"
                RBUFFER="$srbuf"
                zle -D _fzf_ble_cap 2>/dev/null
                unfunction compadd 2>/dev/null   # 防止异常退出时 compadd 残留
            }
            pool=( "${_FZF_BLE_POOL[@]}" )
            _FZF_BLE_POOL=()
        fi

        # ── compadd 未能捕获 或 无注册补全函数：解析 $cmd --help ─────────────
        # 三种情况都走此路径：
        #   ① 无注册补全函数（如 zig、hx 安装前）
        #   ② 有注册函数但 hook 为空——最常见原因是补全函数使用了 _arguments，
        #      其底层 comparguments builtin 绕过了 function-level compadd hook
        #      （典型例子：_hx 用 _arguments -C，hx 选项无法被捕获）
        #   ③ word 以 - 开头（用户想补选项），但 hook 捕获到的全是文件/URL 等非选项候选
        #      （典型例子：_wget 的 _arguments 调用了 _urls→_files→compadd，
        #       捕获到当前目录文件名；这些文件名全不以 - 开头，对选项补全毫无用处）
        if [[ -n "$_ble_cmd" ]] && {
            (( $#pool == 0 )) ||
            { [[ "$word" == -* ]] && (( ${#${(M)pool:#-*}} == 0 )) }
        }; then
            pool=()   # 丢弃无关候选（如文件名），准备用 --help 结果覆盖
            local -a _ble_help_words=()
            local _ble_w
            for _ble_w in ${(Az)prefix}; do
                [[ "$_ble_w" == -* ]] || _ble_help_words+=("$_ble_w")
            done

            # 缓存 key = 命令词列表拼接，同一 session 相同子命令路径只 fork 一次
            local _ble_cache_key="${(j: :)_ble_help_words}"
            local _ble_help_out
            if [[ -n "${_BLE_HELP_CACHE[$_ble_cache_key]+x}" ]]; then
                _ble_help_out="${_BLE_HELP_CACHE[$_ble_cache_key]}"
            else
                _ble_help_out="$(command "${_ble_help_words[@]}" --help 2>&1)"
                _BLE_HELP_CACHE[$_ble_cache_key]="$_ble_help_out"
            fi

            if [[ -n "$_ble_help_out" ]]; then
                _ble_parse_help "$_ble_help_out"
                if [[ "$word" == -* ]]; then
                    pool=( "${_BLE_PARSE_OPTS[@]}" )
                elif (( $#_BLE_PARSE_SUBCMDS )); then
                    pool=( "${_BLE_PARSE_SUBCMDS[@]}" )
                elif (( $#_BLE_PARSE_OPTS )); then
                    # 无子命令但有选项（如 node、hx）
                    # 把 opts 纳入 pool；word 非空时补 -- 前缀，使 "bu" 能匹配 "--build-sea"
                    pool=( "${_BLE_PARSE_OPTS[@]}" )
                    [[ -n "$word" ]] && word="--${word}"
                fi
            fi
        fi
    fi

    pool=( ${(u)pool} )   # 去重

    if (( $#pool == 0 )); then
        # 有注册补全函数但 pool 为空：函数跑了没结果（如 just 在无 justfile 目录）
        #   → 安静退出，不回退，避免再次触发 zle complete-word 产生错误补全
        # 无注册补全函数且 help 也无结果：才回退原生补全（通常做文件补全）
        (( _ble_registered )) || zle complete-word
        return
    fi

    # ── 多级过滤 ─────────────────────────────────────────────────────────────
    _ble_filter "$word" "${pool[@]}"
    local -a show
    if (( $#_BLE_FILTERED )); then
        show=("${_BLE_FILTERED[@]}")
    elif [[ -z "$word" ]]; then
        show=("${pool[@]}")   # word 为空时展示全部（命令名列表等）
    else
        return   # 有输入但无匹配，安静退出，让用户继续打字
    fi

    # 唯一候选直接补全，不展示列表
    if (( $#show == 1 )); then
        LBUFFER="${prefix}${show[1]}"
        zle reset-prompt
        return
    fi

    # ── 填入第一个候选，启动循环模式，展示候选列表 ───────────────────────────
    _BLE_CANDS=( "${show[@]}" )
    _BLE_PFX="$prefix"
    _BLE_IDX=1
    LBUFFER="${_BLE_PFX}${_BLE_CANDS[1]}"
    _ble_show_candidates
}

# ── 历史自动建议 ──────────────────────────────────────────────────────────────
# 在 $history 中从最近记录向前搜索第一条以 needle 开头且比 needle 更长的命令。
# 结果写入全局 _BLE_SUGGESTION（避免 subshell 开销）。
_ble_search_history() {
    local needle="$1"
    _BLE_SUGGESTION=""
    [[ -z "$needle" ]] && return

    local -a nums
    nums=( ${(Onk)history} )   # 事件号从大到小（最近优先）；不加外层引号，否则 @On 把 keys 当单一字符串
    local num entry
    for num in "${nums[@]}"; do
        entry="${history[$num]}"
        if [[ "$entry" == "${needle}"* ]] && [[ "$entry" != "$needle" ]]; then
            _BLE_SUGGESTION="${entry#$needle}"
            return
        fi
    done
}

# POSTDISPLAY + region_highlight 刷新。
# 补全循环中不更新（由 _ble_pre_redraw 清零）；光标不在行尾时隐藏；
# LBUFFER 未变时直接复用缓存，避免每次 pre-redraw 都重新排序 $history。
_ble_update_suggestion() {
    emulate -L zsh
    # 清除旧高亮（memo=ble-sug 标识本插件的条目）
    region_highlight=( ${region_highlight:#*memo=ble-sug} )

    if (( $#_BLE_CANDS )) || (( CURSOR != ${#LBUFFER} )); then
        POSTDISPLAY=""
        return
    fi

    # LBUFFER 未变：复用缓存
    if [[ "$LBUFFER" != "$_BLE_SUGGESTION_NEEDLE" ]]; then
        _ble_search_history "$LBUFFER"
        _BLE_SUGGESTION_NEEDLE="$LBUFFER"
    fi

    POSTDISPLAY="$_BLE_SUGGESTION"
    if [[ -n "$_BLE_SUGGESTION" ]]; then
        local p=${#BUFFER}
        region_highlight+=( "${p} $((p + ${#_BLE_SUGGESTION})) fg=8 memo=ble-sug" )
    fi
}

# 右方向键：有建议时全量接受，否则退化为普通 forward-char。
_ble_autosuggest_accept() {
    emulate -L zsh
    if [[ -n "$POSTDISPLAY" ]]; then
        LBUFFER="${LBUFFER}${POSTDISPLAY}"
        POSTDISPLAY=""
        region_highlight=( ${region_highlight:#*memo=ble-sug} )
        _BLE_SUGGESTION=""
        _BLE_SUGGESTION_NEEDLE="$LBUFFER"
    else
        zle forward-char
    fi
}
zle -N _ble_autosuggest_accept

# ── 包装 accept-line：在最终渲染前清空建议 ────────────────────────────────────
# zle-line-finish 触发时 ZLE 已完成最终渲染，清空 POSTDISPLAY 为时已晚；
# 必须在 accept-line 被调用时立即清空，才能阻止灰色文字随行输出打印到终端。
# 问题根因：accept-line 后 zle-line-pre-redraw 仍会触发一次 _ble_update_suggestion。
# 若把 _BLE_SUGGESTION_NEEDLE 重置为 ""，update-sug 会判断 LBUFFER != needle，
# 重新搜历史并把建议写回 POSTDISPLAY，灰色文字随最终渲染打印到终端。
# 修复：将 needle 设为当前 LBUFFER（而非 ""），使 update-sug 命中缓存，
# 复用已清空的 _BLE_SUGGESTION=""，POSTDISPLAY 保持为空。
_ble_accept_line() {
    emulate -L zsh
    POSTDISPLAY=""
    region_highlight=( ${region_highlight:#*memo=ble-sug} )
    _BLE_SUGGESTION=""
    _BLE_SUGGESTION_NEEDLE="$LBUFFER"   # 锁定 needle，阻止 pre-redraw 重新搜历史
    zle .accept-line
}
zle -N accept-line _ble_accept_line

# ── 自动清除候选菜单 ──────────────────────────────────────────────────────────
# zle-line-pre-redraw 在每次重绘前触发；若上一个 widget 不是本 widget，
# 说明用户做了其他操作（Backspace、输入、方向键等），此时清除菜单和循环状态。
_ble_pre_redraw() {
    emulate -L zsh
    if [[ "$LASTWIDGET" == "_fzf_ble_complete" ]]; then
        # 补全循环期间：清除建议显示，保留候选菜单
        POSTDISPLAY=""
        region_highlight=( ${region_highlight:#*memo=ble-sug} )
        return
    fi
    if (( $#_BLE_CANDS )); then
        _BLE_CANDS=()
        _BLE_IDX=0
        _BLE_PFX=""
        zle -M ""
    fi
    _ble_update_suggestion
}
autoload -Uz add-zle-hook-widget
add-zle-hook-widget zle-line-pre-redraw _ble_pre_redraw

zle -N _fzf_ble_complete
bindkey '^I'   _fzf_ble_complete   # Tab
bindkey '^[[Z' complete-word       # Shift+Tab 保留原生补全
bindkey '^[[C' _ble_autosuggest_accept   # 右方向键（大多数终端）
bindkey '^[OC' _ble_autosuggest_accept   # 右方向键（部分终端）
