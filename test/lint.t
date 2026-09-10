#!/bin/sh
# lint.t - the whole tree, checked for the things a reader cannot see.
#
# There is a pre-commit hook for the 80-column rule, but a hook is opt-in
# (`git config core.hooksPath .githooks`) and `--no-verify` walks past it. So
# the rule also lives here, where the suite enforces it on a fresh clone that
# never enabled the hook. Same reasoning for the rest: each of these is a
# defect that reads as fine and only shows up when someone runs the file.
#
#   syntax      -- a shell file that does not parse is a runtime failure in a
#                  launcher that sits in front of every agent command.
#   80 columns  -- the project's hard limit, for code and prose alike.
#   exec bit    -- a hook or script that is not executable is SILENTLY SKIPPED
#                  by the thing that would have run it (_hooks_in tests -x),
#                  which is exactly the "looks wired, enforces nothing" state
#                  the hook seam exists to avoid.
#   no CRLF     -- a `\r` on the shebang line makes the kernel report the
#                  interpreter as missing, with a message that names the wrong
#                  file.
#
# Runs over the files git would SHIP: tracked, plus untracked ones that are
# not ignored -- so a file added but not yet committed is linted (that is
# exactly when it is easiest to fix), while a gitignored scratch file cannot
# fail the suite. Without git, it walks the tree instead and skips .git.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init lint

# Tracked files, else every file in the tree. Either way, one path per line.
files() {
  if git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$HERE" ls-files --cached --others --exclude-standard |
    while IFS= read -r _f; do
      [ -f "$HERE/$_f" ] && printf '%s\n' "$HERE/$_f"
    done
  else
    find "$HERE" -name .git -prune -o -type f -print
  fi
}

# Is this a shell file? Either a /bin/sh shebang or a name we know is shell.
# The adapters are sourced FRAGMENTS with no shebang, so they are matched by
# location: they still have to parse.
is_shell() {   # <path>
  case ${1#"$HERE"/} in
    libexec/adapters/*) return 0 ;;
    *.sh|test/*.t|test/run) return 0 ;;
  esac
  head -1 "$1" 2>/dev/null | grep -q '^#!.*/sh' && return 0
  return 1
}

# Must this file be executable? Anything the OS or a glob EXECUTES rather than
# sources: the engine, the libs, the hook examples, the git hook. The adapters
# and test/lib.sh are sourced, so their mode does not matter.
wants_exec() {   # <path>
  case ${1#"$HERE"/} in
    bin/*|libexec/slots|libexec/merge/*|setup.sh|share/hooks/*.d/*) return 0 ;;
    .githooks/*) return 0 ;;
  esac
  return 1
}

_n=0; _sh=0
for f in $(files); do
  _n=$((_n + 1))
  rel=${f#"$HERE"/}

  # 80 columns, code and prose alike. awk counts characters, which is what the
  # limit means; a tab would be counted as one, and the tree uses none.
  _wide=$(awk 'length > 80 { printf "%d ", FNR }' "$f")
  [ -z "$_wide" ] || fail "$rel: line(s) over 80 columns: $_wide"

  # A carriage return anywhere, but especially on line 1.
  if grep -q "$(printf '\r')" "$f" 2>/dev/null; then
    fail "$rel: contains CRLF line endings"
  fi

  if is_shell "$f"; then
    _sh=$((_sh + 1))
    dash -n "$f" 2>/dev/null || fail "$rel: does not parse as POSIX sh"
  fi

  if wants_exec "$f"; then
    [ -x "$f" ] || fail "$rel: must be executable (it is run, not sourced)"
  fi
done

[ "$_n" -gt 0 ] || fail "found no files to lint"
[ "$_sh" -gt 0 ] || fail "found no shell files to syntax-check"

# The adapters are the one group whose mode is load-bearing in the OTHER
# direction: the engine SOURCES them, and an executable adapter invites
# someone to run it directly, where its bare `ADAPTER_*=` assignments do
# nothing at all and it exits 0 looking successful.
for a in "$HERE"/libexec/adapters/*; do
  [ -f "$a" ] || continue
  [ -x "$a" ] && fail "adapter ${a##*/} is executable; it is sourced, not run"
done

pass "$_n files, $_sh shell"
