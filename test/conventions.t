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

# --- the detectors ----------------------------------------------------------
# ONE implementation each, called by the rule below AND by the self-test at the
# bottom. Written as functions for exactly that reason: a self-test carrying its
# own copy of a pattern is two patterns free to drift, which is the duplication
# this file exists to remove.
#
# Each echoes its finding and echoes NOTHING when the file is clean, so "did the
# detector fire" is a test of emptiness in both directions.
d_cols() {   # <file> -> line numbers over 80 columns
  awk 'length > 80 { printf "%d ", FNR }' "$1"
}
d_tabs() {   # <file> -> count of TAB-indented lines (0 when clean)
  grep -cP '^[ ]*\t' "$1" 2>/dev/null || true
}
# The banned set is every dash a writer reaches for INSTEAD of punctuation, not
# only the two that turned up first: figure dash, en, em, horizontal bar, the
# two- and three-em dashes, the non-breaking hyphen, the fullwidth hyphen, the
# MINUS SIGN (identical to an em-dash in a comment) and the SOFT HYPHEN,
# invisible and so the worst of them. Measured across all 15 repos: no text file
# holds any of these beyond U+2014/U+2013, so widening costs nothing today and
# closes the hole before someone pastes one in.
DASHES='\x{00AD}|\x{2010}|\x{2011}|\x{2012}|\x{2013}|\x{2014}'
DASHES="$DASHES|\x{2015}|\x{2212}|\x{2E3A}|\x{2E3B}|\x{FF0D}"
d_dash() {   # <file> -> non-empty when a banned dash character is present
  grep -oP "$DASHES" "$1" 2>/dev/null | head -1
}
d_shparse() {   # <file> -> non-empty when it does NOT parse as POSIX sh
  dash -n "$1" >/dev/null 2>&1 || echo failed
}
d_bashparse() {   # <file> -> non-empty when it does NOT parse as bash
  bash -n "$1" >/dev/null 2>&1 || echo failed
}
d_pyindent() {   # <file-list> -> one line per Python indent-step violation
  python3 - "$1" <<'PY'
import sys, tokenize
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
}

# --- the detectors are PROVEN TO FIRE, every run -----------------------------
# Every rule above can only report what its detector detects, and four of them
# lean on an external tool that may be missing or built without a feature:
# grep -P needs PCRE, rule 3 needs python3, rule 8 needs dash and bash. EVERY
# ONE OF THOSE DEGRADED TO SILENCE. Measured, before this section existed:
#
#   python3 hidden      a planted 2-space Python indent -> rc=0, "10 python"
#   grep without -P     a tabbed line -> count empty -> read as 0 tabs
#   grep without -P     a real em-dash -> rule 7 never fires
#   dash absent         a file that does not parse -> reported clean
#
# A missing tool is therefore NOT tiptoed around, and not announced and skipped
# either: each detector is run here against a sample that MUST trip it and a
# sample that must NOT, and a detector that fails either way fails the suite.
# That is the whole no-blind-spot property, and it costs one temp dir per run.
#
# IT RUNS FIRST AND IT IS FATAL. With dash removed, the rules below happily
# reported "setup.sh: does not parse as POSIX sh" about three perfectly good
# files: a tool that cannot start has made no finding, and a message must not
# say otherwise (the same false claim tackup's tackdisk test once made about
# the disk layout). So this gate closes before any rule speaks.
#
# BOTH DIRECTIONS, because a detector wedged ON is as useless as one wedged off:
# it would bury every real finding in noise until someone stopped reading.
SELF=$(mktemp -d)
# ONE trap covering both, replacing the corpus trap above rather than sitting
# beside it: POSIX sh has no trap stack, so a second `trap ... EXIT` would
# silently discard the first and leak $FILES on every run.
trap 'rm -f "$FILES" "$FILES.sh" "$FILES.bash" "$FILES.py"; rm -rf "$SELF"' EXIT
NPROVEN=0
prove() {   # <name> <expect-hit: y|n> <finding>
  case $2 in
    y) [ -n "$3" ] || { note "SELF-TEST: the $1 detector did not fire on a
  planted violation, so rule $1 above is not enforcing anything"; return; } ;;
    n) [ -z "$3" ] || { note "SELF-TEST: the $1 detector fired on a CLEAN
  sample ('$3'), so every finding it reports above is suspect"; return; } ;;
  esac
  NPROVEN=$((NPROVEN + 1))
}

# printf, NOT awk: `awk 'BEGIN{..}END{..}'` with no file argument reads STDIN
# and waits forever, which hung this section the first time it ran. A test that
# BLOCKS is worse than one that fails, so nothing here reads stdin.
printf '%090d\n' 0 > "$SELF/long"
printf 'short line\n' > "$SELF/short"
prove 1-columns y "$(d_cols "$SELF/long")"
prove 1-columns n "$(d_cols "$SELF/short")"

printf '\tindented with a tab\n' > "$SELF/tabbed"
printf '  indented with spaces\n' > "$SELF/spaced"
t=$(d_tabs "$SELF/tabbed");  [ "${t:-0}" -gt 0 ] && t=hit || t=
prove 2-tabs y "$t"
t=$(d_tabs "$SELF/spaced");  [ "${t:-0}" -gt 0 ] && t=hit || t=
prove 2-tabs n "$t"

printf 'def f():\n  return 1\n' > "$SELF/bad.py"
printf 'def f():\n    return 1\n' > "$SELF/good.py"
printf '%s\n' "$SELF/bad.py"  > "$SELF/pylist.bad"
printf '%s\n' "$SELF/good.py" > "$SELF/pylist.good"
prove 3-python y "$(d_pyindent "$SELF/pylist.bad")"
prove 3-python n "$(d_pyindent "$SELF/pylist.good")"

# Built with printf from the codepoint so this file holds no banned character
# itself, which would make it fail its own rule 7.
printf 'an \342\200\224 em dash\n' > "$SELF/dashy"
printf 'an ordinary - hyphen\n'      > "$SELF/clean"
prove 7-dashes y "$(d_dash "$SELF/dashy")"
prove 7-dashes n "$(d_dash "$SELF/clean")"

printf '#!/bin/sh\nif then fi\n' > "$SELF/bad.sh"
printf '#!/bin/sh\nexit 0\n'     > "$SELF/good.sh"
prove 8-sh y "$(d_shparse "$SELF/bad.sh")"
prove 8-sh n "$(d_shparse "$SELF/good.sh")"
printf '#!/bin/bash\nif then fi\n' > "$SELF/bad.bash"
printf '#!/bin/bash\nexit 0\n'     > "$SELF/good.bash"
prove 8-bash y "$(d_bashparse "$SELF/bad.bash")"
prove 8-bash n "$(d_bashparse "$SELF/good.bash")"

# Rules 4, 5 and 6 are pure shell (`case`, `[ -x ]`, `head -c`) with no external
# tool to go missing, so they cannot degrade this way. They are NOT proven here,
# and the pass line counts only what is: a logic bug in them is still possible
# and would need a different kind of test. Said plainly rather than implied.

if [ -n "$bad" ]; then
  printf 'FAIL conventions (SELF-TEST):%s\n' "$bad" >&2
  echo >&2
  echo 'A detector above is not working, so NOTHING ELSE RAN: every rule' >&2
  echo 'below would report clean whether the tree is clean or not. Fix the' >&2
  echo 'tool (grep needs -P/PCRE, rule 3 needs python3, rule 8 needs dash' >&2
  echo 'and bash) rather than reading the result.' >&2
  exit 1
fi

# --- 1. 80 COLUMNS, the hard rule --------------------------------------------
# awk counts CHARACTERS, which is what the limit means.
while IFS= read -r f; do
  w=$(d_cols "$f")
  [ -z "$w" ] || note "$f: over 80 columns at line(s): $w"
done < "$FILES"

# --- 2. NEVER TABS, where the language does not demand them ------------------
# Go and Make are the only two that get tabs, and only because gofmt emits them
# and a make recipe line is REQUIRED to open with one. Indentation only: a tab
# inside a string or a printf format is data.
while IFS= read -r f; do
  case $(lang_of "$f") in go|make) continue ;; esac
  t=$(d_tabs "$f")
  [ "${t:-0}" -eq 0 ] || note "$f: $t line(s) indented with a TAB"
done < "$FILES"

# --- 3. PYTHON INDENTS IN STEPS OF EXACTLY 4 ---------------------------------
# It cannot be written as "the indent is even": 4 gives 4, 8, 12, and so does a
# 2-space file at depth 2. The invariant is the STEP, so walk the INDENT tokens
# and require each new level to be exactly 4 deeper than the one enclosing it.
# Continuation lines are NOT covered: they produce no INDENT token and may
# align to their opening bracket, which is the formatter's call and not ours.
# NO SKIP, AND NO GUARD. python3 is REQUIRED, asserted by the self-test at the
# bottom rather than tiptoed around here. Guarded on `command -v python3` and
# silent, this rule did NOTHING on a box without it while the summary still said
# "N python": a planted 2-space indent gave rc=1 with python3 and rc=0 plus a
# green line without it. Announcing the skip was an improvement and still a
# compromise, because a rule that may not run is a rule you cannot rely on.
if [ -s "$FILES.py" ]; then
  out=$(d_pyindent "$FILES.py") || out='python3 failed to run the indent check'
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
# The character half of the rule. The `--` half (a double hyphen standing in for
# an em-dash) is not here YET: it needs prose-versus-code discrimination that
# POSIX ERE cannot express, so it lands as embedded Python beside rule 3 once
# every repo is at zero. See _common.md, the no-em-dash bullet.
while IFS= read -r f; do
  d=$(d_dash "$f")
  [ -z "$d" ] || note "$f: contains a dash character used as punctuation"
done < "$FILES"

# --- 8. EVERY SHELL FILE PARSES, UNDER ITS OWN INTERPRETER -------------------
# The cheapest empirical check the language offers, and it catches the class
# that reaches a box and fails at the worst moment. DISPATCHED BY SHEBANG: a
# `#!/usr/bin/env bash` script is not POSIX sh, and checking it with dash
# reports a syntax error in perfectly good code (hwdp/bin/run-scaled, the
# first file this ever ran on). Judging a file by a dialect it never claimed
# is how a check earns being ignored.
# NO `command -v` GUARD, for the reason rule 3 lost its one: with dash absent
# this whole rule skipped in silence, so a file that does not parse read as
# clean. The interpreters are required and the self-test proves they work.
while IFS= read -r f; do
  [ -z "$(d_shparse "$f")" ] || note "$f: does not parse as POSIX sh"
done < "$FILES.sh"
while IFS= read -r f; do
  [ -z "$(d_bashparse "$f")" ] || note "$f: does not parse as bash"
done < "$FILES.bash"

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
 shell, $(wc -l < "$FILES.py") python, $NPROVEN detectors proven"
