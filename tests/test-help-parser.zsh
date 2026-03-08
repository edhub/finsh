#!/usr/bin/env zsh
# tests/test-help-parser.zsh
# 测试 _ble_parse_help 函数的 help 输出解析逻辑，以及 _ble_filter 多级匹配逻辑
#
# 用法：
#   zsh tests/test-help-parser.zsh
#
# 无外部依赖，纯 zsh 运行。

emulate -L zsh
setopt extendedglob

# ── 加载被测函数 ──────────────────────────────────────────────────────────────
# 只 source 用到的全局变量声明和 _ble_parse_help / _ble_filter 函数；
# 用 awk 截取到 "_ble_show_candidates" 定义前，避免加载 ZLE/widget 相关代码
# （ZLE 只在 interactive shell 中可用，测试环境无 zle 命令）
_SCRIPT_DIR="${0:A:h}/.."
typeset -ga _BLE_PARSE_SUBCMDS
typeset -ga _BLE_PARSE_OPTS
typeset -ga _BLE_FILTERED
source <(awk '
    /^_ble_parse_help\(\)|^_ble_filter\(\)/ { in_fn=1; brace=0 }
    in_fn { print; brace += gsub(/\{/,"{")-gsub(/\}/,"}"); if (brace==0 && NR>1) in_fn=0 }
' "$_SCRIPT_DIR/fzf-ble-complete.zsh")

# ── 断言工具 ──────────────────────────────────────────────────────────────────
typeset -gi _PASS=0 _FAIL=0

_assert_contains() {
    local -a arr=("${@[1,-3]}")   # 除最后两参数外均为数组元素
    local item="${@[-2]}" msg="${@[-1]}"
    if (( ${arr[(I)${(b)item}]} )); then
        (( _PASS++ ))
        print -P "%F{green}  PASS%f  $msg  →  '$item' ∈ results"
    else
        (( _FAIL++ ))
        print -P "%F{red}  FAIL%f  $msg"
        print    "        expected '${item}' in: ${arr[*]}"
    fi
}

_assert_not_contains() {
    local -a arr=("${@[1,-3]}")
    local item="${@[-2]}" msg="${@[-1]}"
    if (( ! ${arr[(I)${(b)item}]} )); then
        (( _PASS++ ))
        print -P "%F{green}  PASS%f  $msg  →  '$item' ∉ results (correct)"
    else
        (( _FAIL++ ))
        print -P "%F{red}  FAIL%f  $msg"
        print    "        '$item' should NOT be in: ${arr[*]}"
    fi
}

_assert_empty() {
    local -a arr=("${@[1,-2]}")
    local msg="${@[-1]}"
    if (( $#arr == 0 )); then
        (( _PASS++ ))
        print -P "%F{green}  PASS%f  $msg  →  empty (correct)"
    else
        (( _FAIL++ ))
        print -P "%F{red}  FAIL%f  $msg"
        print    "        expected empty, got: ${arr[*]}"
    fi
}

# ── Fixture 辅助 ──────────────────────────────────────────────────────────────
# 每个 fixture 是真实 --help 输出的精简截取（保留格式不变）
run_test() {
    local name="$1" help_text="$2"
    print "\n── $name"
    _ble_parse_help "$help_text"
}

# ─────────────────────────────────────────────────────────────────────────────
# TEST 1: zig --help（2 空格缩进）
# ─────────────────────────────────────────────────────────────────────────────
run_test "zig  (2-space indent)" \
'Usage: zig [command] [options]

Commands:

  build            Build project from build.zig
  fetch            Copy a package into global cache and print its hash
  init             Initialize a Zig package in the current directory

  build-exe        Create executable from source or object files
  build-lib        Create library from source or object files
  build-obj        Create object from source or object files
  test             Perform unit testing
  run              Create executable and run immediately

  ast-check        Look for simple compile errors in any set of files
  fmt              Reformat Zig source into canonical form

  cc               Use Zig as a drop-in C compiler
  env              Print lib path, std path, cache directory, and version
  help             Print this help and exit
  version          Print version number and exit

General Options:

  -h, --help       Print command-specific usage
  --color [auto|off|on]    Enable or disable colored error messages'

_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "build"     "zig: build"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "run"       "zig: run"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "build-exe" "zig: build-exe (带连字符)"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "ast-check" "zig: ast-check (带连字符)"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "fmt"       "zig: fmt"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "cc"        "zig: cc (两字母)"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "version"   "zig: version"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--help"    "zig: --help 选项"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--color"   "zig: --color 选项"
# 描述文字不应被误匹配（首字母大写，已被 [a-z] 排除）
_assert_not_contains "${_BLE_PARSE_SUBCMDS[@]}" "Build"   "zig: 描述词 'Build' 不应入池"
_assert_not_contains "${_BLE_PARSE_SUBCMDS[@]}" "Print"   "zig: 描述词 'Print' 不应入池"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 2: git --help（3 空格缩进，分区标题行插入）
# ─────────────────────────────────────────────────────────────────────────────
run_test "git  (3-space indent, section headers)" \
'usage: git [-v | --version] [-h | --help] <command> [<args>]

These are common Git commands used in various situations:

start a working area (see also: git help tutorial)
   clone      Clone a repository into a new directory
   init       Create an empty Git repository or reinitialize an existing one

work on the current change (see also: git help everyday)
   add        Add file contents to the index
   mv         Move or rename a file, a directory, or a symlink
   restore    Restore working tree files
   rm         Remove files from the working tree and from the index

grow, mark and tweak your common history
   branch     List, create, or delete branches
   commit     Record changes to the repository
   merge      Join two or more development histories together
   rebase     Reapply commits on top of another base tip
   switch     Switch branches
   tag        Create, list, delete or verify a tag object signed with GPG

collaborate (see also: git help workflows)
   fetch      Download objects and refs from another repository
   pull       Fetch from and integrate with another repository or a local branch
   push       Update remote refs along with associated objects'

_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "clone"   "git: clone"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "init"    "git: init"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "add"     "git: add"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "commit"  "git: commit"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "push"    "git: push"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "switch"  "git: switch"
# 分区标题行（无缩进）不应匹配
_assert_not_contains "${_BLE_PARSE_SUBCMDS[@]}" "start"       "git: 分区标题 'start' 不应入池"
_assert_not_contains "${_BLE_PARSE_SUBCMDS[@]}" "collaborate" "git: 分区标题 'collaborate' 不应入池"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 3: cargo --help（4 空格缩进，逗号别名 "build, b"）
# ─────────────────────────────────────────────────────────────────────────────
run_test "cargo  (4-space indent, comma aliases)" \
'Rust'\''s package manager

Usage: cargo [+toolchain] [OPTIONS] [COMMAND]

Options:
  -V, --version                  Print version info and exit
      --list                     List installed commands
      --explain <CODE>           Provide a detailed explanation of a rustc error message
  -v, --verbose...               Use verbose output (-vv very verbose/build.rs output)
  -q, --quiet                    Do not print cargo log messages
      --color <WHEN>             Coloring [possible values: auto, always, never]
      --locked                   Assert that `Cargo.lock` will remain unchanged
      --offline                  Run without accessing the network
  -h, --help                     Print help

Commands:
    build, b    Compile the current package
    check, c    Analyze the current package and report errors, but don'\''t build object files
    clean       Remove the target directory
    doc, d      Build this package'\''s and its dependencies'\'' documentation
    new         Create a new cargo package
    add         Add dependencies to a manifest file
    run, r      Run a binary or example of the local package
    test, t     Run the tests
    install     Install a Rust binary
    uninstall   Uninstall a Rust binary
    ...         See all commands with --list'

_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "build"     "cargo: build"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "b"         "cargo: b (build 的别名)"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "check"     "cargo: check"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "c"         "cargo: c (check 的别名)"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "clean"     "cargo: clean"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "install"   "cargo: install"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--version" "cargo: --version 选项"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--list"    "cargo: --list 选项（无短格式）"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--quiet"   "cargo: --quiet 选项"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--offline" "cargo: --offline 选项"
# "..." 不应入池（不匹配 [a-z][-a-z0-9]*）
_assert_not_contains "${_BLE_PARSE_SUBCMDS[@]}" "..."  "cargo: '...' 不应入池"
# Bug 18：描述文字里的逗号不应切出假词
_assert_not_contains "${_BLE_PARSE_SUBCMDS[@]}" "but"  "cargo Bug18: 描述里的 'but' 不应入池"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 4: npm --help（4 空格缩进，多行逗号列表）
# ─────────────────────────────────────────────────────────────────────────────
run_test "npm  (4-space, multi-line comma list)" \
'npm <command>

All commands:

    access, adduser, audit, bugs, cache, ci, completion,
    config, dedupe, deprecate, diff, dist-tag, docs, doctor,
    edit, exec, explain, explore, fund, get, help,
    init, install, link, ls, org, outdated, owner, pack,
    ping, publish, query, rebuild, run, search,
    test, token, uninstall, update, version, view, whoami'

_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "access"    "npm: access"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "install"   "npm: install"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "publish"   "npm: publish"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "test"      "npm: test"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "whoami"    "npm: whoami (最后一个词)"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "dist-tag"  "npm: dist-tag (带连字符)"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "run"       "npm: run"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 5: docker --help（2 空格缩进，带 * 后缀的行）
# ─────────────────────────────────────────────────────────────────────────────
run_test "docker  (2-space indent, trailing * on buildx)" \
'Usage:  docker [OPTIONS] COMMAND

Common Commands:
  run         Create and run a new container from an image
  exec        Execute a command in a running container
  ps          List containers
  build       Build an image from a Dockerfile
  pull        Download an image from a registry
  push        Upload an image to a registry

Management Commands:
  builder     Manage builds
  buildx*     Docker Buildx (plugin)
  container   Manage containers
  image       Manage images
  network     Manage networks
  volume      Manage volumes

Commands:
  attach      Attach local standard input, output, and error streams
  commit      Create a new image from a container'\''s changes
  logs        Fetch the logs of a container

Global Options:
      --config string      Location of client config files
  -D, --debug              Enable debug mode
  -H, --host list          Daemon socket to connect to
      --log-level string   Set the logging level
  -v, --version            Print version information and quit'

_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "run"       "docker: run"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "build"     "docker: build"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "ps"        "docker: ps (两字母)"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "buildx"    "docker: buildx（* 后缀应被截断）"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "container" "docker: container"
_assert_contains "${_BLE_PARSE_SUBCMDS[@]}" "logs"      "docker: logs"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--config"  "docker: --config 选项"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--debug"   "docker: --debug 选项"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--version" "docker: --version 选项"
# "buildx*" 不应整体入池
_assert_not_contains "${_BLE_PARSE_SUBCMDS[@]}" "buildx*" "docker: 'buildx*' 不应整体入池"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 6: hx --help（clap 风格，USAGE:/ARGS:/FLAGS: 纯大写 section，无子命令）
# ─────────────────────────────────────────────────────────────────────────────
# 状态机路径：
#   USAGE: → other（跳过 "    hx [FLAGS]..." 行，避免 hx 误入子命令池）
#   ARGS:  → other（跳过 "<files>..." 行）
#   FLAGS: → opts（提取所有 --flag）
#   续行（35+ 空格对齐）在 opts 状态下不含 --，自然跳过
run_test "hx  (clap style: USAGE:/FLAGS: sections, no subcommands)" \
'helix-term 25.07.1 (a05c151b)
A post-modern text editor.

USAGE:
    hx [FLAGS] [files]...

ARGS:
    <files>...    Sets the input file to use

FLAGS:
    -h, --help                     Prints help information
    --tutor                        Loads the tutorial
    --health [CATEGORY]            Checks for potential errors in editor setup
                                   CATEGORY can be a language or one of all
                                   or all. all is the default if not specified.
    -g, --grammar {fetch|build}    Fetches or builds tree-sitter grammars
    -c, --config <file>            Specifies a file to use for configuration
    -v                             Increases logging verbosity each use
    --log <file>                   Specifies a file to use for logging
    -V, --version                  Prints version information
    --vsplit                       Splits all given files vertically
    --hsplit                       Splits all given files horizontally
    -w, --working-dir <path>       Specify an initial working directory
    +N                             Open the first given file at line number N'

# 选项全部应被捕获
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--help"        "hx: --help"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--tutor"       "hx: --tutor"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--health"      "hx: --health"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--grammar"     "hx: --grammar"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--config"      "hx: --config"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--log"         "hx: --log"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--version"     "hx: --version"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--vsplit"      "hx: --vsplit"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--hsplit"      "hx: --hsplit"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--working-dir" "hx: --working-dir"
# hx 无子命令
_assert_empty "${_BLE_PARSE_SUBCMDS[@]}"    "hx: 无子命令"
# USAGE: 段内容不应误入子命令池（旧实现的假阳性）
_assert_not_contains "${_BLE_PARSE_SUBCMDS[@]}" "hx" "hx: USAGE 行里的 'hx' 不应入池"
# 35+ 空格续行里的 'or' 不应误入子命令池（旧实现的假阳性）
_assert_not_contains "${_BLE_PARSE_SUBCMDS[@]}" "or" "hx: 续行里的 'or' 不应入池"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 7: node --help（只有选项，无子命令；非 - 开头的 word 应匹配 --flag）
# ─────────────────────────────────────────────────────────────────────────────
# node 选项格式：多行描述，"  --flag" 后大量空格或直接换行
# "Options:" section header → opts 状态
run_test "node  (opts-only, non-dash word should match --flags)" \
'Usage: node [options] [ script.js ] [arguments]

Options:
  --abort-on-uncaught-exception
                              aborting instead of exiting causes a core file
  --allow-addons              allow use of addons when any permissions are set
  --build-sea=...             Build a Node.js single executable application
  --build-snapshot            Generate a snapshot blob when the process exits.
  --build-snapshot-config=... Generate a snapshot blob when the process exits
  -c, --check                 syntax check script without executing
  --completion-bash           print source-able bash completion script
  --inspect                   Activate inspector on 127.0.0.1:9229
  --inspect-brk               Activate inspector, break before user code starts
  --no-warnings               silence all process warnings
  --version                   print Node.js version'

_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--build-sea"       "node: --build-sea"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--build-snapshot"  "node: --build-snapshot"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--inspect"         "node: --inspect"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--check"           "node: --check (有短格式 -c,)"
_assert_contains "${_BLE_PARSE_OPTS[@]}"    "--version"         "node: --version"
_assert_empty    "${_BLE_PARSE_SUBCMDS[@]}"                     "node: 无子命令"

# 模拟 widget 路由：word="bu" → 补 -- 前缀后应匹配 --build-*
local _word="bu" _pool=()
if [[ "$_word" == -* ]]; then
    _pool=( "${_BLE_PARSE_OPTS[@]}" )
elif (( $#_BLE_PARSE_SUBCMDS )); then
    _pool=( "${_BLE_PARSE_SUBCMDS[@]}" )
elif (( $#_BLE_PARSE_OPTS )); then
    _pool=( "${_BLE_PARSE_OPTS[@]}" )
    [[ -n "$_word" ]] && _word="--${_word}"
fi
_ble_filter "$_word" "${_pool[@]}"
_assert_contains "${_BLE_FILTERED[@]}" "--build-sea"      "node routing: 'bu' 匹配 --build-sea"
_assert_contains "${_BLE_FILTERED[@]}" "--build-snapshot" "node routing: 'bu' 匹配 --build-snapshot"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 8: wget --help（多字符短选项 -nv, -nc, -4, -6 — Bug 19）
# ─────────────────────────────────────────────────────────────────────────────
run_test "wget  (multi-char short options: -nv, -nc, -4, -6 — Bug 19)" \
'GNU Wget 1.21.4, a non-interactive network retriever.
Usage: wget [OPTION]... [URL]...

Startup:
  -V,  --version           display the version of Wget and exit
  -h,  --help              print this help
  -b,  --background        go to background after startup
  -e,  --execute=COMMAND   execute a .wgetrc-style command

Logging and input file:
  -o,  --output-file=FILE  log messages to FILE
  -a,  --append-output=FILE  append messages to FILE
  -nv, --no-verbose        turn off verboseness, without being quiet
  -nc, --no-clobber        skip downloads that would download to existing files
  -4,  --inet4-only        connect only to IPv4 addresses
  -6,  --inet6-only        connect only to IPv6 addresses
  -q,  --quiet             quiet (no output)
  -v,  --verbose           be verbose (this is the default)
       --no-dns-cache      Disable caching DNS lookups.'

_assert_contains "${_BLE_PARSE_OPTS[@]}" "--version"      "wget Bug19: --version (单字母短选项)"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--help"         "wget Bug19: --help"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--no-verbose"   "wget Bug19: --no-verbose (多字符短选项 -nv,)"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--no-clobber"   "wget Bug19: --no-clobber (多字符短选项 -nc,)"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--inet4-only"   "wget Bug19: --inet4-only (数字短选项 -4,)"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--inet6-only"   "wget Bug19: --inet6-only (数字短选项 -6,)"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--quiet"        "wget Bug19: --quiet"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--verbose"      "wget Bug19: --verbose"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--no-dns-cache" "wget Bug19: --no-dns-cache (无短格式)"
_assert_empty    "${_BLE_PARSE_SUBCMDS[@]}"               "wget: 无子命令"

run_test "edge: 空输入" ""

_assert_empty "${_BLE_PARSE_SUBCMDS[@]}" "空输入：subcmds 应为空"
_assert_empty "${_BLE_PARSE_OPTS[@]}"    "空输入：opts 应为空"

run_test "edge: 无缩进行不应匹配" \
'build    compile the project
run      run the project
--help   show help'

_assert_empty "${_BLE_PARSE_SUBCMDS[@]}" "无缩进：subcmds 应为空（缩进不足 2 空格）"

run_test "edge: 纯选项（无子命令）" \
'Options:
  -v, --verbose    Verbose output
  -q, --quiet      Quiet output
      --dry-run    Dry run mode
  -o, --output <file>  Output file'

_assert_empty "${_BLE_PARSE_SUBCMDS[@]}"    "纯选项：subcmds 应为空"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--verbose"  "纯选项: --verbose"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--quiet"    "纯选项: --quiet"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--dry-run"  "纯选项: --dry-run"
_assert_contains "${_BLE_PARSE_OPTS[@]}" "--output"   "纯选项: --output"

run_test "edge: 描述中含 -- 不应匹配为选项" \
'  build    compile (use --release for optimized build)
  test     run tests'

_assert_contains     "${_BLE_PARSE_SUBCMDS[@]}" "build"     "描述含--：build 正常入池"
_assert_contains     "${_BLE_PARSE_SUBCMDS[@]}" "test"      "描述含--：test 正常入池"
_assert_not_contains "${_BLE_PARSE_OPTS[@]}"    "--release" "描述含--：描述里的 --release 不入选项池"

# ─────────────────────────────────────────────────────────────────────────────
# _ble_filter 单元测试
# ─────────────────────────────────────────────────────────────────────────────

print "\n── _ble_filter: Pass 1（精确前缀）"
local -a _p=("pi-claude" "pi-cat" "python" "pi" "perl")
_ble_filter "pi" "${_p[@]}"
_assert_contains     "${_BLE_FILTERED[@]}" "pi-claude" "Pass1: pi → pi-claude"
_assert_contains     "${_BLE_FILTERED[@]}" "pi-cat"    "Pass1: pi → pi-cat"
_assert_contains     "${_BLE_FILTERED[@]}" "pi"        "Pass1: pi → pi（精确匹配）"
_assert_not_contains "${_BLE_FILTERED[@]}" "python"    "Pass1: 前缀 pi 不含 python"
_assert_not_contains "${_BLE_FILTERED[@]}" "perl"      "Pass1: 前缀 pi 不含 perl"

print "\n── _ble_filter: Pass 2a（substring）"
# "claude" 在 pi-claude 中作为子串匹配；首字母预过滤要求以 'c' 开头的候选，
# pi-claude 不以 'c' 开头 → Pass 2a 实际上被首字母预过滤截断
# 正确用例：needle 首字母与候选首字母一致才触发 substring
local -a _p2a=("pi-claude" "pi-cat" "cp-claude" "curl")
_ble_filter "cl" "${_p2a[@]}"
_assert_contains     "${_BLE_FILTERED[@]}" "cp-claude"  "Pass2a: cl(首字母c) substring → cp-claude"
_assert_not_contains "${_BLE_FILTERED[@]}" "pi-claude"  "Pass2a: pi-claude 首字母 p ≠ c，预过滤排除"

print "\n── _ble_filter: Pass 2b（head-anchored subsequence）"
local -a _p2b=("pi-claude" "pi-cat" "python" "pi-clude")
_ble_filter "piclaud" "${_p2b[@]}"
_assert_contains     "${_BLE_FILTERED[@]}" "pi-claude"  "Pass2b: piclaud → pi-claude"
_assert_not_contains "${_BLE_FILTERED[@]}" "pi-cat"     "Pass2b: piclaud 不含 pi-cat（无 'laud'）"
_assert_not_contains "${_BLE_FILTERED[@]}" "python"     "Pass2b: piclaud 不含 python"

print "\n── _ble_filter: Pass 2c（pure subsequence）"
local -a _p2c=("pi-claude" "python" "perlclude")
_ble_filter "pclaud" "${_p2c[@]}"
_assert_contains     "${_BLE_FILTERED[@]}" "pi-claude"  "Pass2c: pclaud → pi-claude (*p*c*l*a*u*d*)"
_assert_not_contains "${_BLE_FILTERED[@]}" "python"     "Pass2c: pclaud 不含 python（无 'claud'）"

print "\n── _ble_filter: 首字母预过滤"
local -a _p_pre=("python" "pi-claude" "apply" "pep")
_ble_filter "py" "${_p_pre[@]}"
_assert_contains     "${_BLE_FILTERED[@]}" "python"    "首字母过滤: py → python"
_assert_not_contains "${_BLE_FILTERED[@]}" "apply"     "首字母过滤: apply 首字母 a，不在 py 候选里"
_assert_not_contains "${_BLE_FILTERED[@]}" "pi-claude" "首字母过滤: pi-claude 不含 'py' 前缀"

print "\n── _ble_filter: word 为空时 FILTERED 为空（调用方直接用原始 pool）"
local -a _p_empty=("foo" "bar")
_ble_filter "" "${_p_empty[@]}"
_assert_empty "${_BLE_FILTERED[@]}" "_ble_filter: word='' 时 FILTERED 为空"

print "\n── _ble_filter: 无匹配时 FILTERED 为空"
local -a _p_nm=("foo" "bar" "baz")
_ble_filter "px" "${_p_nm[@]}"
_assert_empty "${_BLE_FILTERED[@]}" "_ble_filter: 无匹配（首字母 p 但无候选以 p 开头）"

print "\n── _ble_filter: glob 元字符转义（--release 含连字符）"
local -a _p_glob=("--release" "--debug" "--output")
_ble_filter "--rel" "${_p_glob[@]}"
_assert_contains     "${_BLE_FILTERED[@]}" "--release" "glob转义: --rel → --release"
_assert_not_contains "${_BLE_FILTERED[@]}" "--debug"   "glob转义: --rel 不含 --debug"

print "\n── _ble_filter: 路径 basename 过滤（模拟路径补全场景）"
local -a _p_path=("fzf-ble-complete.zsh" "README.md" "DESIGN.md" "fzf-complete.sh")
_ble_filter "fzf-b" "${_p_path[@]}"
_assert_contains     "${_BLE_FILTERED[@]}" "fzf-ble-complete.zsh" "路径: fzf-b → fzf-ble-complete.zsh"
_assert_not_contains "${_BLE_FILTERED[@]}" "README.md"            "路径: fzf-b 不含 README.md"
_assert_not_contains "${_BLE_FILTERED[@]}" "fzf-complete.sh"      "路径: fzf-b 不含 fzf-complete.sh（无 '-b'）"

# ─────────────────────────────────────────────────────────────────────────────
# 结果汇总
# ─────────────────────────────────────────────────────────────────────────────
print ""
print "────────────────────────────────────────"
if (( _FAIL == 0 )); then
    print -P "%F{green}All $_PASS tests passed.%f"
else
    print -P "%F{red}$_FAIL FAILED%f, $_PASS passed  (total $(( _PASS + _FAIL )))"
fi
print "────────────────────────────────────────"
(( _FAIL == 0 ))   # 非零退出码表示有失败
