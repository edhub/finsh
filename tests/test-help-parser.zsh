#!/usr/bin/env zsh
# tests/test-help-parser.zsh
# Unit tests for _finsh_parse_help help-output parsing logic and
# _finsh_filter multi-pass matching logic.
#
# Usage:
#   zsh tests/test-help-parser.zsh
#
# No external dependencies; runs in plain zsh.

emulate -L zsh
setopt extendedglob

# ── Load functions under test ─────────────────────────────────────────────────
# Source only the global variable declarations and the
# _finsh_parse_help / _finsh_filter / _finsh_parse_man functions.
# awk extracts everything up to (but not including) the _finsh_show_candidates
# definition, so ZLE/widget code is never loaded — zle is only available in
# interactive shells and is not present in the test environment.
_SCRIPT_DIR="${0:A:h}/.."
typeset -ga _FINSH_PARSE_SUBCMDS
typeset -ga _FINSH_PARSE_OPTS
typeset -ga _FINSH_FILTERED
source <(awk '
    /^_finsh_parse_comma_list\(\)|^_finsh_parse_help\(\)|^_finsh_filter\(\)|^_finsh_parse_man\(\)/ { in_fn=1; brace=0 }
    in_fn { print; brace += gsub(/\{/,"{")-gsub(/\}/,"}"); if (brace==0 && NR>1) in_fn=0 }
' "$_SCRIPT_DIR/finsh.zsh")

# ── Assertion helpers ─────────────────────────────────────────────────────────
typeset -gi _PASS=0 _FAIL=0

_assert_contains() {
    local -a arr=("${@[1,-3]}")   # all but the last two arguments form the array
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

# ── Fixture helper ────────────────────────────────────────────────────────────
# Each fixture is an abbreviated excerpt of real --help output (format preserved).
run_test() {
    local name="$1" help_text="$2"
    print "\n── $name"
    _finsh_parse_help "$help_text"
}

# ─────────────────────────────────────────────────────────────────────────────
# TEST 1: zig --help (2-space indent)
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

_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "build"     "zig: build"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "run"       "zig: run"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "build-exe" "zig: build-exe (hyphenated)"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "ast-check" "zig: ast-check (hyphenated)"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "fmt"       "zig: fmt"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "cc"        "zig: cc (two letters)"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "version"   "zig: version"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--help"    "zig: --help option"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--color"   "zig: --color option"
# Description words (uppercase first letter) must not be matched ([a-z] excludes them)
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "Build"   "zig: description word 'Build' must not enter pool"
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "Print"   "zig: description word 'Print' must not enter pool"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 2: git --help (3-space indent, section header lines inserted)
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

_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "clone"   "git: clone"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "init"    "git: init"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "add"     "git: add"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "commit"  "git: commit"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "push"    "git: push"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "switch"  "git: switch"
# Section header lines (no indent) must not be matched
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "start"       "git: section header 'start' must not enter pool"
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "collaborate" "git: section header 'collaborate' must not enter pool"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 3: cargo --help (4-space indent, comma aliases "build, b")
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

_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "build"     "cargo: build"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "b"         "cargo: b (alias for build)"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "check"     "cargo: check"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "c"         "cargo: c (alias for check)"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "clean"     "cargo: clean"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "install"   "cargo: install"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--version" "cargo: --version option"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--list"    "cargo: --list option (no short form)"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--quiet"   "cargo: --quiet option"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--offline" "cargo: --offline option"
# "..." must not enter the pool (does not match [a-z][-a-z0-9]*)
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "..."  "cargo: '...' must not enter pool"
# Bug 18: commas inside the description must not produce spurious tokens
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "but"  "cargo Bug18: 'but' from description must not enter pool"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 4: npm --help (4-space indent, multi-line comma list)
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

_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "access"    "npm: access"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "install"   "npm: install"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "publish"   "npm: publish"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "test"      "npm: test"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "whoami"    "npm: whoami (last word on line)"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "dist-tag"  "npm: dist-tag (hyphenated)"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "run"       "npm: run"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 5: docker --help (2-space indent, trailing * on buildx)
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

_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "run"       "docker: run"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "build"     "docker: build"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "ps"        "docker: ps (two letters)"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "buildx"    "docker: buildx (trailing * should be stripped)"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "container" "docker: container"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "logs"      "docker: logs"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--config"  "docker: --config option"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--debug"   "docker: --debug option"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--version" "docker: --version option"
# "buildx*" must not enter the pool as a literal string
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "buildx*" "docker: 'buildx*' must not enter pool as-is"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 6: hx --help (clap style: USAGE:/ARGS:/FLAGS: all-caps sections, no subcommands)
# ─────────────────────────────────────────────────────────────────────────────
# State machine path:
#   USAGE: → other  (skip "    hx [FLAGS]..." to prevent 'hx' from entering subcmds)
#   ARGS:  → other  (skip "<files>..." lines)
#   FLAGS: → opts   (extract all --flags)
#   Continuation lines (35+ space alignment) contain no --, so they are skipped naturally
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

# All options must be captured
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--help"        "hx: --help"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--tutor"       "hx: --tutor"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--health"      "hx: --health"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--grammar"     "hx: --grammar"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--config"      "hx: --config"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--log"         "hx: --log"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--version"     "hx: --version"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--vsplit"      "hx: --vsplit"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--hsplit"      "hx: --hsplit"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--working-dir" "hx: --working-dir"
# hx has no subcommands
_assert_empty "${_FINSH_PARSE_SUBCMDS[@]}"    "hx: no subcommands"
# USAGE: section content must not enter the subcmds pool (false positive in old implementation)
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "hx" "hx: 'hx' from USAGE line must not enter pool"
# 'or' from a 35+-space continuation line must not enter the subcmds pool
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "or" "hx: 'or' from continuation line must not enter pool"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 7: node --help (options only, no subcommands; non-dash word should match --flags)
# ─────────────────────────────────────────────────────────────────────────────
# node option format: multi-line descriptions, "  --flag" followed by many spaces or a newline
# "Options:" section header → opts state
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

_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--build-sea"       "node: --build-sea"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--build-snapshot"  "node: --build-snapshot"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--inspect"         "node: --inspect"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--check"           "node: --check (has short form -c,)"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--version"         "node: --version"
_assert_empty    "${_FINSH_PARSE_SUBCMDS[@]}"                     "node: no subcommands"

# Simulate widget routing: word="bu" → prepend "--" → should match --build-*
local _word="bu" _pool=()
if [[ "$_word" == -* ]]; then
    _pool=( "${_FINSH_PARSE_OPTS[@]}" )
elif (( $#_FINSH_PARSE_SUBCMDS )); then
    _pool=( "${_FINSH_PARSE_SUBCMDS[@]}" )
elif (( $#_FINSH_PARSE_OPTS )); then
    _pool=( "${_FINSH_PARSE_OPTS[@]}" )
    [[ -n "$_word" ]] && _word="--${_word}"
fi
_finsh_filter "$_word" "${_pool[@]}"
_assert_contains "${_FINSH_FILTERED[@]}" "--build-sea"      "node routing: 'bu' matches --build-sea"
_assert_contains "${_FINSH_FILTERED[@]}" "--build-snapshot" "node routing: 'bu' matches --build-snapshot"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 8: wget --help (multi-char short options -nv, -nc, -4, -6 — Bug 19)
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

_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--version"      "wget Bug19: --version (single-char short option)"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--help"         "wget Bug19: --help"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--no-verbose"   "wget Bug19: --no-verbose (multi-char short option -nv,)"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--no-clobber"   "wget Bug19: --no-clobber (multi-char short option -nc,)"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--inet4-only"   "wget Bug19: --inet4-only (digit short option -4,)"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--inet6-only"   "wget Bug19: --inet6-only (digit short option -6,)"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--quiet"        "wget Bug19: --quiet"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--verbose"      "wget Bug19: --verbose"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--no-dns-cache" "wget Bug19: --no-dns-cache (no short form)"
_assert_empty    "${_FINSH_PARSE_SUBCMDS[@]}"               "wget: no subcommands"

run_test "edge: empty input" ""

_assert_empty "${_FINSH_PARSE_SUBCMDS[@]}" "empty input: subcmds should be empty"
_assert_empty "${_FINSH_PARSE_OPTS[@]}"    "empty input: opts should be empty"

run_test "edge: unindented lines should not match" \
'build    compile the project
run      run the project
--help   show help'

_assert_empty "${_FINSH_PARSE_SUBCMDS[@]}" "no indent: subcmds should be empty (indent < 2 spaces)"

run_test "edge: options only (no subcommands)" \
'Options:
  -v, --verbose    Verbose output
  -q, --quiet      Quiet output
      --dry-run    Dry run mode
  -o, --output <file>  Output file'

_assert_empty "${_FINSH_PARSE_SUBCMDS[@]}"    "opts-only: subcmds should be empty"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--verbose"  "opts-only: --verbose"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--quiet"    "opts-only: --quiet"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--dry-run"  "opts-only: --dry-run"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "--output"   "opts-only: --output"

run_test "edge: -- inside description must not be matched as an option" \
'  build    compile (use --release for optimized build)
  test     run tests'

_assert_contains     "${_FINSH_PARSE_SUBCMDS[@]}" "build"     "desc-with-dash: build enters pool normally"
_assert_contains     "${_FINSH_PARSE_SUBCMDS[@]}" "test"      "desc-with-dash: test enters pool normally"
_assert_not_contains "${_FINSH_PARSE_OPTS[@]}"    "--release" "desc-with-dash: --release inside description must not enter opts pool"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 9: cobra standard format ("Available Commands:" section, no program prefix)
# ─────────────────────────────────────────────────────────────────────────────
run_test "cobra  (Available Commands, standard format without program prefix)" \
'A CLI tool built with cobra

Usage:
  mytool [command]

Available Commands:
  completion  Generate autocompletion script for the specified shell
  help        Help about any command
  install     Install a package
  remove      Remove a package
  update      Update packages

Flags:
  -h, --help      help for mytool
  -v, --verbose   verbose output
      --version   Print version'

_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "completion" "cobra std: completion"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "help"       "cobra std: help"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "install"    "cobra std: install"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "remove"     "cobra std: remove"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "update"     "cobra std: update"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--help"     "cobra std: --help flag"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--verbose"  "cobra std: --verbose flag"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--version"  "cobra std: --version flag"
# Description words must not enter the pool
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "Generate" "cobra std: description word must not enter pool"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 10: cobra pi-style ("  pi subcmd" lines with program name prefix)
# ─────────────────────────────────────────────────────────────────────────────
print "\n── cobra/pi-style  (Available Commands, program name prefix)"
_finsh_parse_help \
'pi is a coding agent

Usage:
  pi [command]

Available Commands:
  pi install    Install packages
  pi update     Update packages
  pi remove     Remove a package
  pi list       List installed packages
  pi <command>  Run arbitrary command (placeholder — must be skipped)

Flags:
  -h, --help      help for pi
  -v, --verbose   verbose output' "pi"

_assert_contains     "${_FINSH_PARSE_SUBCMDS[@]}" "install"    "pi cobra: install"
_assert_contains     "${_FINSH_PARSE_SUBCMDS[@]}" "update"     "pi cobra: update"
_assert_contains     "${_FINSH_PARSE_SUBCMDS[@]}" "remove"     "pi cobra: remove"
_assert_contains     "${_FINSH_PARSE_SUBCMDS[@]}" "list"       "pi cobra: list"
_assert_contains     "${_FINSH_PARSE_OPTS[@]}"    "--help"     "pi cobra: --help flag"
_assert_contains     "${_FINSH_PARSE_OPTS[@]}"    "--verbose"  "pi cobra: --verbose flag"
# "<command>" placeholder must not enter the pool (does not match [a-z][-a-z0-9]*)
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "<command>"  "pi cobra: '<command>' placeholder must not enter pool"

# ─────────────────────────────────────────────────────────────────────────────
# _finsh_parse_comma_list unit tests
# ─────────────────────────────────────────────────────────────────────────────

print "\n── _finsh_parse_comma_list: direct unit tests"

_FINSH_PARSE_SUBCMDS=()
_finsh_parse_comma_list "    build, b  Compile the project"
_assert_contains     "${_FINSH_PARSE_SUBCMDS[@]}" "build"   "_finsh_parse_comma_list: build"
_assert_contains     "${_FINSH_PARSE_SUBCMDS[@]}" "b"       "_finsh_parse_comma_list: b (alias)"
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "Compile" "_finsh_parse_comma_list: description word 'Compile' must not enter pool"

_FINSH_PARSE_SUBCMDS=()
_finsh_parse_comma_list "    check, c    Analyze the package for errors, but don't build"
_assert_contains     "${_FINSH_PARSE_SUBCMDS[@]}" "check" "_finsh_parse_comma_list: check"
_assert_contains     "${_FINSH_PARSE_SUBCMDS[@]}" "c"     "_finsh_parse_comma_list: c (alias)"
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "but"   "_finsh_parse_comma_list: Bug18 'but' from description must not enter pool"
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "don"   "_finsh_parse_comma_list: 'don' from description must not enter pool"

_FINSH_PARSE_SUBCMDS=()
_finsh_parse_comma_list "    run, r  Run a binary"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "run" "_finsh_parse_comma_list: run"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "r"   "_finsh_parse_comma_list: r (single-char alias)"

# ─────────────────────────────────────────────────────────────────────────────
# _finsh_parse_man unit tests
# ─────────────────────────────────────────────────────────────────────────────

run_man_test() {
    local name="$1" man_text="$2"
    print "\n── [man] $name"
    _finsh_parse_man "$man_text"
}

# TEST M1: BSD tool options embedded in DESCRIPTION (ssh / cp style)
# DESCRIPTION has no colon and is all-uppercase → other state;
# options with -x + 1+ spaces should be captured
run_man_test "ssh-style  (options in DESCRIPTION, no OPTIONS section)" \
'NAME
     ssh -- OpenSSH remote login client

SYNOPSIS
     ssh [-46AaCfGgKkMNnqsTtVvXxYy] [-b bind_address] [-c cipher_spec]
         user@hostname

DESCRIPTION
     ssh (SSH client) is a program for logging into a remote machine.

     The options are as follows:

     -4      Forces ssh to use IPv4 addresses only.

     -6      Forces ssh to use IPv6 addresses only.

     -A      Enables forwarding of connections from an authentication agent.

     -a      Disables forwarding of the authentication agent connection.

     -b bind_address
             Use bind_address on the local machine as the source address.

     -C      Requests compression of all data.

     -f      Requests ssh to go to background before command execution.

     -N      Do not execute a remote command.

     -v      Verbose mode.

FILES
     ~/.ssh/config    User configuration file'

_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-4" "ssh-man: -4"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-6" "ssh-man: -6"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-A" "ssh-man: -A"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-a" "ssh-man: -a"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-b" "ssh-man: -b (option with argument)"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-C" "ssh-man: -C"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-f" "ssh-man: -f"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-N" "ssh-man: -N"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-v" "ssh-man: -v"
_assert_empty    "${_FINSH_PARSE_SUBCMDS[@]}"    "ssh-man: no subcommands"
# FILES section content must not produce false positives in the opts pool
_assert_not_contains "${_FINSH_PARSE_OPTS[@]}" "-s" "ssh-man: no false positive -s from FILES path"

# TEST M2: cp-style (5-space + -x + 4-space gap between flag and description)
run_man_test "cp-style  (4-space gap between flag and description)" \
'NAME
     cp -- copy files

DESCRIPTION
     The following options are available:

     -H    If the -R option is specified, symbolic links on the command line
           are followed.

     -L    If the -R option is specified, all symbolic links are followed.

     -P    No symbolic links are followed.  This is the default.

     -R    If source_file designates a directory, cp copies recursively.

     -f    For each existing destination pathname, remove it and create new.

     -i    Cause cp to write a prompt before copying to existing file.

     -n    Do not overwrite an existing file.

     -v    Cause cp to be verbose, showing files as they are copied.

SEE ALSO
     mv(1), ln(1)'

_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-H" "cp-man: -H"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-L" "cp-man: -L"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-P" "cp-man: -P"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-R" "cp-man: -R"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-f" "cp-man: -f"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-i" "cp-man: -i"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-n" "cp-man: -n"
_assert_contains "${_FINSH_PARSE_OPTS[@]}" "-v" "cp-man: -v"
_assert_empty    "${_FINSH_PARSE_SUBCMDS[@]}"    "cp-man: no subcommands"
# SEE ALSO section (mv(1), ln(1)) must not produce false positives
_assert_not_contains "${_FINSH_PARSE_OPTS[@]}" "-m" "cp-man: no false positive from SEE ALSO"

# TEST M3: tool with an explicit COMMANDS section (simple CLI man page)
run_man_test "custom-cli  (explicit COMMANDS section, all-caps no-colon)" \
'NAME
     mycli -- a simple CLI tool

COMMANDS
     init [-f] [-q]
           Initialize a new project.

     build [--release] [--target arch]
           Build the project.

     test [-v] [-r pattern]
           Run test suite.

     deploy
           Deploy the project.

OPTIONS
     -h      Show help and exit.
     -v      Enable verbose output.
     --version
             Print version and exit.'

_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "init"   "custom-man COMMANDS: init"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "build"  "custom-man COMMANDS: build"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "test"   "custom-man COMMANDS: test"
_assert_contains "${_FINSH_PARSE_SUBCMDS[@]}" "deploy" "custom-man COMMANDS: deploy (no flags)"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "-h"     "custom-man OPTIONS: -h"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "-v"     "custom-man OPTIONS: -v"
_assert_contains "${_FINSH_PARSE_OPTS[@]}"    "--version" "custom-man OPTIONS: --version"
# Description lines in the COMMANDS section must not enter the subcmds pool
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "Initialize" "custom-man: description word must not enter pool"
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "Build"      "custom-man: description word must not enter pool"

# TEST M4: tmux-style (commands under non-COMMANDS sub-sections; verify no crash)
# Expected: subcmds is empty (tmux commands spread across CLIENTS AND SESSIONS etc.)
run_man_test "tmux-style  (commands under non-COMMANDS sections, expected empty subcmds)" \
'NAME
     tmux -- terminal multiplexer

COMMANDS
     This section describes the commands supported by tmux.  Most commands
     accept the optional -t argument with one of target-client, target-session,
     target-window, or target-pane.

     target-session is tried as, in order:

           1.   A session ID prefixed with a $.

CLIENTS AND SESSIONS
     The following commands are available to manage clients and sessions:

     attach-session [-dErx] [-c working-directory] [-f flags] [-t target-session]
           (alias: attach)
           If run from outside tmux, attach to target-session.'

# tmux commands are in CLIENTS AND SESSIONS (other state), so they are not
# collected → subcmds is empty. Should return gracefully without crashing.
_assert_empty "${_FINSH_PARSE_SUBCMDS[@]}" "tmux-man: subcmds empty (commands in sub-sections — known limitation)"
# Prose lines in the COMMANDS section must not enter the pool ("target-session is tried...")
_assert_not_contains "${_FINSH_PARSE_SUBCMDS[@]}" "target-session" "tmux-man: prose line 'target-session is tried' must not enter pool"

# TEST M5: empty input for man page parser
run_man_test "man: empty input" ""
_assert_empty "${_FINSH_PARSE_SUBCMDS[@]}" "man empty input: subcmds should be empty"
_assert_empty "${_FINSH_PARSE_OPTS[@]}"    "man empty input: opts should be empty"

# ─────────────────────────────────────────────────────────────────────────────
# _finsh_filter unit tests
# ─────────────────────────────────────────────────────────────────────────────

print "\n── _finsh_filter: Pass 1 (exact prefix)"
local -a _p=("pi-claude" "pi-cat" "python" "pi" "perl")
_finsh_filter "pi" "${_p[@]}"
_assert_contains     "${_FINSH_FILTERED[@]}" "pi-claude" "Pass1: pi → pi-claude"
_assert_contains     "${_FINSH_FILTERED[@]}" "pi-cat"    "Pass1: pi → pi-cat"
_assert_contains     "${_FINSH_FILTERED[@]}" "pi"        "Pass1: pi → pi (exact match)"
_assert_not_contains "${_FINSH_FILTERED[@]}" "python"    "Pass1: prefix 'pi' does not include python"
_assert_not_contains "${_FINSH_FILTERED[@]}" "perl"      "Pass1: prefix 'pi' does not include perl"

print "\n── _finsh_filter: Pass 2a (substring)"
# "claude" is a substring of pi-claude, but the first-letter pre-filter requires
# candidates to start with 'c' when needle starts with 'c'.
# pi-claude does not start with 'c' → Pass 2a is blocked by the first-letter pre-filter.
# Correct test case: needle's first letter must match the candidate's first letter.
local -a _p2a=("pi-claude" "pi-cat" "cp-claude" "curl")
_finsh_filter "cl" "${_p2a[@]}"
_assert_contains     "${_FINSH_FILTERED[@]}" "cp-claude"  "Pass2a: cl (first letter c) substring → cp-claude"
_assert_not_contains "${_FINSH_FILTERED[@]}" "pi-claude"  "Pass2a: pi-claude starts with p ≠ c, pre-filtered out"

print "\n── _finsh_filter: Pass 2b (head-anchored subsequence)"
local -a _p2b=("pi-claude" "pi-cat" "python" "pi-clude")
_finsh_filter "piclaud" "${_p2b[@]}"
_assert_contains     "${_FINSH_FILTERED[@]}" "pi-claude"  "Pass2b: piclaud → pi-claude"
_assert_not_contains "${_FINSH_FILTERED[@]}" "pi-cat"     "Pass2b: piclaud does not match pi-cat (no 'laud')"
_assert_not_contains "${_FINSH_FILTERED[@]}" "python"     "Pass2b: piclaud does not match python"

print "\n── _finsh_filter: Pass 2c (pure subsequence)"
local -a _p2c=("pi-claude" "python" "perlclude")
_finsh_filter "pclaud" "${_p2c[@]}"
_assert_contains     "${_FINSH_FILTERED[@]}" "pi-claude"  "Pass2c: pclaud → pi-claude (*p*c*l*a*u*d*)"
_assert_not_contains "${_FINSH_FILTERED[@]}" "python"     "Pass2c: pclaud does not match python (no 'claud')"

print "\n── _finsh_filter: first-letter pre-filter"
local -a _p_pre=("python" "pi-claude" "apply" "pep")
_finsh_filter "py" "${_p_pre[@]}"
_assert_contains     "${_FINSH_FILTERED[@]}" "python"    "first-letter filter: py → python"
_assert_not_contains "${_FINSH_FILTERED[@]}" "apply"     "first-letter filter: 'apply' starts with 'a', excluded"
_assert_not_contains "${_FINSH_FILTERED[@]}" "pi-claude" "first-letter filter: pi-claude does not have 'py' prefix"

print "\n── _finsh_filter: empty word → FILTERED is empty (caller uses raw pool directly)"
local -a _p_empty=("foo" "bar")
_finsh_filter "" "${_p_empty[@]}"
_assert_empty "${_FINSH_FILTERED[@]}" "_finsh_filter: word='' → FILTERED is empty"

print "\n── _finsh_filter: no match → FILTERED is empty"
local -a _p_nm=("foo" "bar" "baz")
_finsh_filter "px" "${_p_nm[@]}"
_assert_empty "${_FINSH_FILTERED[@]}" "_finsh_filter: no match (first letter p but no candidate starts with p)"

print "\n── _finsh_filter: glob metacharacter escaping (--release contains hyphens)"
local -a _p_glob=("--release" "--debug" "--output")
_finsh_filter "--rel" "${_p_glob[@]}"
_assert_contains     "${_FINSH_FILTERED[@]}" "--release" "glob escape: --rel → --release"
_assert_not_contains "${_FINSH_FILTERED[@]}" "--debug"   "glob escape: --rel does not include --debug"

print "\n── _finsh_filter: path basename filtering (simulated path completion)"
local -a _p_path=("finsh.zsh" "README.md" "DESIGN.md" "fzf-complete.sh")
_finsh_filter "fi" "${_p_path[@]}"
_assert_contains     "${_FINSH_FILTERED[@]}" "finsh.zsh" "path: fi → finsh.zsh"
_assert_not_contains "${_FINSH_FILTERED[@]}" "README.md"            "path: fi does not include README.md"
_assert_not_contains "${_FINSH_FILTERED[@]}" "fzf-complete.sh"      "path: fi does not include fzf-complete.sh (same first letter f but 'fi' is not a substring)"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print ""
print "────────────────────────────────────────"
if (( _FAIL == 0 )); then
    print -P "%F{green}All $_PASS tests passed.%f"
else
    print -P "%F{red}$_FAIL FAILED%f, $_PASS passed  (total $(( _PASS + _FAIL )))"
fi
print "────────────────────────────────────────"
(( _FAIL == 0 ))   # non-zero exit code indicates failures
