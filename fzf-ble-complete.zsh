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

    zle -M "${(j:\n:)out}"
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
        local dir="${word:h}" base="${word:t}"
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

        else
            # ── 无注册补全函数：解析 $cmd [subcmd…] --help ───────────────────
            # 根据 word 类型分流：
            #   word 以 - 开头 → 收集 --flag 候选（选项）
            #   否则           → 收集子命令候选
            #
            # 运行命令：取 prefix 中所有非 - 开头的词（去掉临时 flag），追加 --help
            # 例：prefix="cargo build -v " → 运行 cargo build --help
            if [[ -n "$_ble_cmd" ]]; then
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
                    local _ble_help_line
                    local -a _ble_opts=() _ble_subcmds=()
                    while IFS= read -r _ble_help_line; do
                        # 选项行：  -x, --long  或       --long
                        if [[ "$_ble_help_line" =~ \
                            '^[[:space:]]+((-[a-zA-Z],?[[:space:]]+)?)(--([a-zA-Z][a-zA-Z0-9-]*))' ]]; then
                            _ble_opts+=("--$match[4]")
                        # 子命令行：恰好 4 空格缩进，首词小写字母开头（非 -）
                        elif [[ "$_ble_help_line" =~ \
                            '^    ([a-z][-a-z0-9]*)' ]]; then
                            _ble_subcmds+=("$match[1]")
                        fi
                    done <<< "$_ble_help_out"

                    if [[ "$word" == -* ]]; then
                        pool=( "${_ble_opts[@]}" )
                    else
                        pool=( "${_ble_subcmds[@]}" )
                    fi
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

# ── 自动清除候选菜单 ──────────────────────────────────────────────────────────
# zle-line-pre-redraw 在每次重绘前触发；若上一个 widget 不是本 widget，
# 说明用户做了其他操作（Backspace、输入、方向键等），此时清除菜单和循环状态。
_ble_pre_redraw() {
    emulate -L zsh
    [[ "$LASTWIDGET" == "_fzf_ble_complete" ]] && return
    (( $#_BLE_CANDS )) || return
    _BLE_CANDS=()
    _BLE_IDX=0
    _BLE_PFX=""
    zle -M ""
}
autoload -Uz add-zle-hook-widget
add-zle-hook-widget zle-line-pre-redraw _ble_pre_redraw

zle -N _fzf_ble_complete
bindkey '^I'   _fzf_ble_complete   # Tab
bindkey '^[[Z' complete-word       # Shift+Tab 保留原生补全
