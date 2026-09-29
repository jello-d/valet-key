#!/bin/sh
# test/conventions.t - the house code-style rules, enforced.
#
# CANONICAL COPY: ~/src/shared-notes/_conventions.t. This file is VENDORED into
# each repo (a real file, not a symlink) because a standalone clone from GitHub
# must be able to run its own suite with nothing else present. `tackup notes
# check` compares every vendored copy against the canonical one and names the
# drift, so the copies cannot quietly diverge. EDIT THE CANONICAL COPY, then
# re-seed: `tackup notes conventions`.
#
# It enforces the "Code style" section of ~/src/shared-notes/_common.md. That
# file is the SPEC and this is the ENFORCEMENT; they live beside each other on
# purpose, because a rule whose checker lives somewhere else drifts from it.
#
# SELF-CONTAINED, AND PLAIN. It sources no harness and prints plain ok/FAIL,
# even though most of these repos have a styled harness, because the repos
# expose four different harness APIs and adapting to each would reintroduce
# exactly the per-repo variation this file exists to remove. One byte-identical
# file everywhere is worth more than one matching line of output.
#
# PER-REPO EXEMPTIONS go in `conventions.exempt` BESIDE this file: one path glob
# per line, # comments and blanks ignored. That is the only thing a repo may
# vary, and it is data, not code. Vendored upstream, generated output and patch
# payloads belong there; nothing else should.
set -eu

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=
[ -n "$ROOT" ] || { echo "FAIL conventions: not a git repo" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
EXEMPT=$HERE/conventions.exempt
cd "$ROOT"

bad=''
note() { bad="$bad
  $1"; }
pass() { printf 'ok   conventions (%s)\n' "$1"; }
finish() {
  [ -z "$bad" ] || {
    printf 'FAIL conventions:%s\n' "$bad" >&2
    printf '\nThese are the house rules in ~/src/CLAUDE.md, "Code style".\n' >&2
    # $ROOT is quoted SEPARATELY: inside ${..#..} the right-hand side is a
    # PATTERN, so an unquoted expansion glob-matches. A repo path holding a
    # bracket or a `?` then fails to strip and this prints the absolute path
    # instead of the relative one (SC2295).
    printf 'A deliberate exception goes in %s.\n' "${EXEMPT#"$ROOT"/}" >&2
    exit 1
  }
}

# --- the corpus --------------------------------------------------------------
# Tracked files only: what is committed is what the rules are about. Binary and
# exempt paths drop out here, once, so every rule below sees the same set.
exempt_match() {   # <relpath>
  [ -f "$EXEMPT" ] || return 1
  while IFS= read -r _g; do
    case $_g in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254  # the glob is the point
    case $1 in $_g) return 0 ;; esac
  done < "$EXEMPT"
  return 1
}

FILES=$(mktemp)
trap 'rm -f "$FILES" "$FILES.sh" "$FILES.bash" "$FILES.py"' EXIT
git ls-files | while IFS= read -r f; do
  [ -f "$f" ] || continue
  # A tracked symlink out of the tree is another package's file, not ours.
  if [ -L "$f" ]; then
    case $(readlink -f -- "$f" 2>/dev/null || echo /) in
      "$ROOT"/*) ;;
      *) continue ;;
    esac
  fi
  if file -b --mime "$f" 2>/dev/null | grep -q 'charset=binary'; then
    continue
  fi
  if exempt_match "$f"; then continue; fi
  printf '%s\n' "$f"
done > "$FILES"
[ -s "$FILES" ] ||
  { echo "FAIL conventions: no tracked text files" >&2; exit 1; }
N=$(wc -l < "$FILES")

# Language by CONTENT, never by name: the naming rule strips suffixes off
# executables, so a name-keyed classifier would miss every one of them.
lang_of() {   # <path> -> sh | bash | python | go | make | other
  case $1 in
    Makefile|*/Makefile|*.mk|GNUmakefile) echo make; return ;;
    *.go) echo go; return ;;
    *.py) echo python; return ;;
    *_lib) ;;                       # fall through to the shebang test
  esac
  case $(head -1 "$1" 2>/dev/null) in
    '#!'*python*) echo python; return ;;
    '#!'*/bash|'#!'*bin/env\ bash) echo bash; return ;;
    '#!'*/sh|'#!'*bin/env\ sh) echo sh; return ;;
  esac
  case $1 in *_lib) echo sh; return ;; esac
  echo other
}

while IFS= read -r f; do
  case $(lang_of "$f") in
    sh)     printf '%s\n' "$f" >> "$FILES.sh" ;;
    bash)   printf '%s\n' "$f" >> "$FILES.bash" ;;
    python) printf '%s\n' "$f" >> "$FILES.py" ;;
  esac
done < "$FILES"
touch "$FILES.sh" "$FILES.bash" "$FILES.py"

# --- 1. 80 COLUMNS, the hard rule --------------------------------------------
# awk counts CHARACTERS, which is what the limit means.
while IFS= read -r f; do
  w=$(awk 'length > 80 { printf "%d ", FNR }' "$f")
  [ -z "$w" ] || note "$f: over 80 columns at line(s): $w"
done < "$FILES"

# --- 2. NEVER TABS, where the language does not demand them ------------------
# Go and Make are the only two that get tabs, and only because gofmt emits them
# and a make recipe line is REQUIRED to open with one. Indentation only: a tab
# inside a string or a printf format is data.
while IFS= read -r f; do
  case $(lang_of "$f") in go|make) continue ;; esac
  t=$(grep -cP '^[ ]*\t' "$f" 2>/dev/null || true)
  [ "${t:-0}" -eq 0 ] || note "$f: $t line(s) indented with a TAB"
done < "$FILES"

# --- 3. PYTHON INDENTS IN STEPS OF EXACTLY 4 ---------------------------------
# It cannot be written as "the indent is even": 4 gives 4, 8, 12, and so does a
# 2-space file at depth 2. The invariant is the STEP, so walk the INDENT tokens
# and require each new level to be exactly 4 deeper than the one enclosing it.
# Continuation lines are NOT covered: they produce no INDENT token and may
# align to their opening bracket, which is the formatter's call and not ours.
if [ -s "$FILES.py" ] && command -v python3 >/dev/null 2>&1; then
  out=$(python3 - "$FILES.py" <<'PY'
import io, sys, tokenize
bad = []
for p in open(sys.argv[1]).read().split():
    stack = [0]
    try:
        with open(p, 'rb') as fh:
            for t in tokenize.tokenize(fh.readline):
                if t.type == tokenize.INDENT:
                    w = len(t.string.expandtabs(8))
                    if w - stack[-1] != 4:
                        bad.append("%s:%d indents %d past %d (want a step of 4)"
                                   % (p, t.start[0], w - stack[-1], stack[-1]))
                    stack.append(w)
                elif t.type == tokenize.DEDENT and len(stack) > 1:
                    stack.pop()
    except Exception as e:
        bad.append("%s: will not tokenize: %s" % (p, e))
print("\n".join(bad))
PY
  ) || out='python3 failed to run the indent check'
  [ -z "$out" ] || note "$(printf '%s' "$out" | sed 's/^/  /')"
fi

# --- 4. *_lib IS SOURCED, NEVER EXECUTED -------------------------------------
# The classifier is the contract. An executable *_lib invites someone to run
# it, where its bare assignments do nothing and it exits 0 looking successful.
while IFS= read -r f; do
  case $f in *_lib) ;; *) continue ;; esac
  # `if`, not `[ ... ] && note`: a false AND-list as the LAST statement in a
  # loop body returns 1 and set -e kills the loop, so the rule would stop
  # checking at the first compliant file and still report green.
  if [ -x "$f" ]; then
    note "$f: is executable, but _lib means SOURCED, never run"
  fi
  # A shebang on a sourced file is FINE and deliberately not flagged: editors
  # and shellcheck dispatch on it, and sourcing ignores it entirely.
done < "$FILES"

# --- 5. AN EXECUTED FILE TAKES A BARE NAME -----------------------------------
# Rewriting foo.py in another language breaks every caller for no reason; foo
# does not. A name fixed by a CONTRACT is frozen, whoever set it: setup.sh is
# this fleet's package contract and module-setup.sh is dracut's module API.
while IFS= read -r f; do
  [ -x "$f" ] || continue
  case $(head -c 2 "$f" 2>/dev/null) in '#!') ;; *) continue ;; esac
  case ${f##*/} in
    setup.sh|module-setup.sh) continue ;;
    *.sh|*.py|*.bash|*.pl|*.rb)
      note "$f: is EXECUTED, so it takes a bare name (drop the suffix)" ;;
  esac
done < "$FILES"

# --- 6. IN bin/, THE EXEC BIT AND THE SHEBANG AGREE --------------------------
# A shebang says "run me"; no exec bit means nobody can. But that only BREAKS
# something where the file is meant to be typed or resolved by name, which is
# bin/. Everywhere else the repo mode says nothing about how the file runs, and
# three separate classes prove it:
#   - test/*.t            every extracted repo's runner does `sh "$_t"`, so the
#                         shebang is for editors and the mode is irrelevant.
#   - deploy/ payloads    installed elsewhere with an explicit mode (modules/
#                         fprint does `install -m 0755`), so the source mode is
#                         not the deployed one.
#   - install/venvs/*.post run via `sh`, and install_lib says so in as many
#                         words: "run via sh so it needs no +x".
# A rule that flagged all three would be wrong three ways and get ignored. So
# it asks the narrow question where the answer matters.
while IFS= read -r f; do
  case $f in */bin/*|bin/*) ;; *) continue ;; esac
  case $f in *_lib) continue ;; esac       # sourced: rule 4 owns its mode
  s=no; [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ] && s=yes
  x=no; [ -x "$f" ] && x=yes
  [ "$s" = "$x" ] && continue
  if [ "$s" = yes ]; then
    note "$f: in bin/ with a shebang but NOT executable, so it cannot be run"
  else
    note "$f: in bin/ and executable but has NO shebang: interpreter is a guess"
  fi
done < "$FILES"

# --- 7. NO EM-DASHES, in prose, comments and docs alike ----------------------
while IFS= read -r f; do
  if grep -qP '\x{2014}|\x{2013}' "$f" 2>/dev/null; then
    note "$f: contains an em- or en-dash"
  fi
done < "$FILES"

# --- 8. EVERY SHELL FILE PARSES, UNDER ITS OWN INTERPRETER -------------------
# The cheapest empirical check the language offers, and it catches the class
# that reaches a box and fails at the worst moment. DISPATCHED BY SHEBANG: a
# `#!/usr/bin/env bash` script is not POSIX sh, and checking it with dash
# reports a syntax error in perfectly good code (hwdp/bin/run-scaled, the
# first file this ever ran on). Judging a file by a dialect it never claimed
# is how a check earns being ignored.
if command -v dash >/dev/null 2>&1; then
  while IFS= read -r f; do
    dash -n "$f" 2>/dev/null || note "$f: does not parse as POSIX sh"
  done < "$FILES.sh"
fi
if command -v bash >/dev/null 2>&1; then
  while IFS= read -r f; do
    bash -n "$f" 2>/dev/null || note "$f: does not parse as bash"
  done < "$FILES.bash"
fi

# --- the check is not vacuous ------------------------------------------------
# DERIVED, not a floor. Every rule above draws from $FILES, so if the corpus
# silently shrank to a handful the whole suite would pass having looked at
# almost nothing. Compare against the tree it claims to cover.
tracked=$(git ls-files | wc -l)
[ "$N" -gt 0 ] || note "the corpus is empty; every rule above examined nothing"
if [ "$tracked" -gt 20 ] && [ "$N" -lt 5 ]; then
  note "only $N of $tracked tracked files were examined; the corpus builder or
  the exemption list has swallowed the tree and these rules are vacuous"
fi

finish
pass "$N files, $(( $(wc -l < "$FILES.sh") + $(wc -l < "$FILES.bash") ))\
 shell, $(wc -l < "$FILES.py") python"
