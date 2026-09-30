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
# ROFF SPELLS AN EM-DASH IN ASCII, so d_dash above can never see it: a
# backslash then (em. It renders as a real em-dash in the man page a user
# reads. 91 were live across eight repos when this was added; the groff long
# form, a backslash then [em], is the same thing.
# Rules 4, 5 and 6 are FILESYSTEM-SHAPE questions: a name, a mode, a shebang.
# They need no external tool, so they cannot go silent the way 1/2/3/7/8 did.
# They are still extracted and still proven, because "cannot degrade" is not
# "cannot be wrong", and the pass line used to admit they were unproven.
d_libexec() {   # <file> -> non-empty when a *_lib file is executable
  case $1 in *_lib) [ -x "$1" ] && echo executable ;; esac
}
d_barename() {   # <file> -> non-empty when an EXECUTED file keeps a suffix
  [ -x "$1" ] || return 0
  [ "$(head -c 2 "$1" 2>/dev/null)" = '#!' ] || return 0
  case ${1##*/} in
    setup.sh|module-setup.sh) ;;             # frozen by contract, not ours
    *.sh|*.py|*.bash|*.pl|*.rb) echo suffixed ;;
  esac
}
d_binmode() {   # <file> -> shebang/exec-bit disagreement in bin/, else empty
  case $1 in */bin/*|bin/*) ;; *) return 0 ;; esac
  case $1 in *_lib) return 0 ;; esac        # sourced: rule 4 owns its mode
  _s=no; [ "$(head -c 2 "$1" 2>/dev/null)" = '#!' ] && _s=yes
  _x=no; [ -x "$1" ] && _x=yes
  [ "$_s" = "$_x" ] && return 0
  [ "$_s" = yes ] && echo unrunnable || echo noshebang
}
d_roff() {   # <file> -> non-empty when a roff dash escape is present
  grep -oE '\\[([]e[mn][])]?' "$1" 2>/dev/null | head -1
}
# THE `--` HALF, the half the house rule spends its words on and the half
# nothing enforced. It needs prose-versus-code discrimination that POSIX ERE
# cannot express (no lookaround), and Python docstrings need a real lexer, so it
# is embedded Python beside rule 3 rather than an awk approximation.
#
# WHAT IS PROSE: markdown outside fenced and indented blocks; COMMENT and STRING
# tokens in Python, via tokenize, because a docstring is prose and scanning only
# `#` lines missed 139 in one repo; roff BODY text, where a control line is
# excluded so `.B --` still bolds a literal dash; and elsewhere a comment
# line PLUS the quoted parts of a line that prints something, because output is
# prose the user reads and 85 of those were live in tackup alone.
# WHAT IS NOT: a `--` inside backticks, an end-of-options marker (`cd --`,
# `set --`, `printf --`, `grep -qxF --`), a run of three or more (a divider),
# and a symmetric `-- banner --`.
#
# A LINE MAY OPT OUT with `conventions: allow --` and a reason, suppressing
# from the marker to the next blank or comment-only line. That is what a quoted
# transcript or a published CLI signature needs, and it is per-site so a second
# ACCIDENTAL one still fails. The inline-disable convention mux/lint.t states.
d_dashdash() {   # <file-list> -> one line per prose double-dash
  python3 - "$1" <<'PY'
import io, re, sys, tokenize

ALLOW = re.compile(r'conventions:\s*allow\s*--')
DASH  = re.compile(r'(?:(?<=\s)|^)(?<!-)--(?!-)(?=\s|$)')
OUTCALL = re.compile(r'(^|[;&|(]|\bthen\b|\belse\b|\bdo\b)\s*'
                     r'(printf|echo|_ok|_bad|_warn|_ignore|_fault|_status|'
                     r'fail|pass|die|note|say|warn|bad)\b')
ARGM  = re.compile(r'(^|[;&|(`\s])(cd|set|eval|exec|printf|command|readlink|'
                   r'pgrep|pkill|xargs|install|chown|chmod|rm|cp|mv|grep|sed|'
                   r'awk|find|git|echo|tar|dd|env|test|parted|sgdisk|mkfs|'
                   r'mount|umount|dpkg|apt-get|systemctl|kubectl|ssh|sudo|'
                   r'\[)\b[^`]{0,40}--(\s|$)')

def visible(line):
    parts = line.split('`')
    return ''.join(p for k, p in enumerate(parts) if k % 2 == 0)

def banner(line):
    t = line.strip().lstrip('#').strip()
    return len(t) > 3 and t.startswith('--') and t.endswith('--')

def prose_lines(path):
    """{lineno: text} for the lines that are PROSE in this file's language."""
    try:
        txt = open(path, encoding='utf-8', errors='replace').read()
    except Exception:
        return {}
    if path.endswith('.py'):
        got = {}
        try:
            for tok in tokenize.generate_tokens(io.StringIO(txt).readline):
                if tok.type not in (tokenize.COMMENT, tokenize.STRING):
                    continue
                for off, l in enumerate(tok.string.splitlines()):
                    got[tok.start[0] + off] = l
        except Exception:
            return {}
        return got
    lines = txt.splitlines()
    if path.endswith('.md'):
        got, fence = {}, False
        for n, l in enumerate(lines, 1):
            if l.strip().startswith('```'):
                fence = not fence
                continue
            if fence or re.match(r'^\s{4,}\S', l):
                continue
            got[n] = l
        return got
    if re.search(r'\.[1-8]$', path) or '/man/' in path:
        # ROFF: a line opening with . or ' is a CONTROL line (a macro; `.B`
        # legitimately bolds a literal double hyphen), and everything else is
        # body PROSE, which the `#`-comment branch below would never have seen.
        # Measured across 9 man pages: zero violations, so this was free.
        return {n: l for n, l in enumerate(lines, 1)
                if l[:1] not in ('.', "'")}
    # A comment line, plus the QUOTED PARTS of a line that PRINTS something. An
    # output string is prose the user reads, and scanning only comments missed
    # every one of them: 85 were live in tackup alone. Narrow to a recognised
    # output call so an ordinary assignment holding a `--` flag stays out.
    got = {}
    for n, l in enumerate(lines, 1):
        m = re.match(r'^\s*#(.*)$', l)
        if m:
            got[n] = m.group(1)
        elif OUTCALL.search(l):
            # PER SEGMENT, and banners dropped here: joining `"-- tail --"` with
            # the next argument hides the symmetric shape and reports a divider
            # as prose. Each quoted string is judged as the string it is.
            segs = [(a if a is not None else b) for a, b in
                    re.findall(r'"([^"]*)"|\'([^\']*)\'', l)]
            keep = [x for x in segs if not banner(x)]
            if keep:
                got[n] = ' | '.join(keep)
    return got

out = []
for p in open(sys.argv[1]).read().split():
    try:
        raw = open(p, encoding='utf-8', errors='replace').read().splitlines()
    except Exception:
        continue
    allowed, until = set(), 0
    for n, l in enumerate(raw, 1):
        if ALLOW.search(l):
            until = n
        if until and n >= until:
            # A comment-only marker line ('#', '//') is a PARAGRAPH boundary in
            # these files, so it ends the suppression too. Without that, a
            # marker placed in a long comment block would silently cover the
            # rest of it, and the escape hatch would quietly widen.
            if l.strip() in ('', '#', '//', '.\\"'):
                until = 0
            else:
                allowed.add(n)
    for n, text in sorted(prose_lines(p).items()):
        if n in allowed or banner(text):
            continue
        v = visible(text)
        if ARGM.search(v) or not DASH.search(v):
            continue
        out.append("%s:%d: %s" % (p, n, text.strip()[:60]))
print("\n".join(out))
PY
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

# Built with printf from the byte sequence so this file holds no banned dash
# itself, which would make it fail its own rule 7.
printf 'roff \134(em here\n' > "$SELF/roffy"
printf 'spelled with a plain - hyphen\n' > "$SELF/roffclean"
prove 7-roff y "$(d_roff "$SELF/roffy")"
prove 7-roff n "$(d_roff "$SELF/roffclean")"

# The double-dash detector, over a LIST like the real rule takes. Four samples:
# prose must fire; an argument marker, a divider and an opted-out line must
# not. The opt-out is proven here because an escape hatch nobody tests is one
# that silently stops working, and then every marked line is unchecked.
printf '# a clause -- and its continuation\n'      > "$SELF/dd.sh"
printf '# cd -- /some/path is an argument marker\n' > "$SELF/dd-arg.sh"
printf '# --- a divider ---------------------\n'   > "$SELF/dd-div.sh"
printf '# conventions: allow -- quoted output\n# it said -- verbatim\n' \
  > "$SELF/dd-ok.sh"
printf '%s\n' "$SELF/dd.sh"     > "$SELF/ddlist.bad"
printf '%s\n' "$SELF/dd-arg.sh" "$SELF/dd-div.sh" "$SELF/dd-ok.sh" \
  > "$SELF/ddlist.good"
prove 7-dashdash y "$(d_dashdash "$SELF/ddlist.bad")"
prove 7-dashdash n "$(d_dashdash "$SELF/ddlist.good")"

printf '#!/bin/sh\nif then fi\n' > "$SELF/bad.sh"
printf '#!/bin/sh\nexit 0\n'     > "$SELF/good.sh"
prove 8-sh y "$(d_shparse "$SELF/bad.sh")"
prove 8-sh n "$(d_shparse "$SELF/good.sh")"
printf '#!/bin/bash\nif then fi\n' > "$SELF/bad.bash"
printf '#!/bin/bash\nexit 0\n'     > "$SELF/good.bash"
prove 8-bash y "$(d_bashparse "$SELF/bad.bash")"
prove 8-bash n "$(d_bashparse "$SELF/good.bash")"

# Rules 4, 5 and 6 are FILESYSTEM SHAPE, not a tool, so they cannot go silent
# the way the five above did. Proven anyway: "cannot degrade" is not "cannot be
# wrong", and until now the pass line had to admit they were unchecked.
mkdir -p "$SELF/bin"
printf '#!/bin/sh\nexit 0\n' > "$SELF/a_lib";   chmod +x "$SELF/a_lib"
printf '#!/bin/sh\nexit 0\n' > "$SELF/b_lib";   chmod -x "$SELF/b_lib"
prove 4-libexec y "$(d_libexec "$SELF/a_lib")"
prove 4-libexec n "$(d_libexec "$SELF/b_lib")"

printf '#!/bin/sh\nexit 0\n' > "$SELF/tool.sh";  chmod +x "$SELF/tool.sh"
printf '#!/bin/sh\nexit 0\n' > "$SELF/setup.sh"; chmod +x "$SELF/setup.sh"
prove 5-barename y "$(d_barename "$SELF/tool.sh")"
prove 5-barename n "$(d_barename "$SELF/setup.sh")"

printf '#!/bin/sh\nexit 0\n' > "$SELF/bin/cmd";  chmod -x "$SELF/bin/cmd"
printf '#!/bin/sh\nexit 0\n' > "$SELF/bin/ok";   chmod +x "$SELF/bin/ok"
prove 6-binmode y "$(d_binmode "$SELF/bin/cmd")"
prove 6-binmode n "$(d_binmode "$SELF/bin/ok")"


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
  # `if`, not `[ ... ] && note`: a false AND-list as the LAST statement in a
  # loop body returns 1 and set -e kills the loop, so the rule would stop
  # checking at the first compliant file and still report green.
  if [ -n "$(d_libexec "$f")" ]; then
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
  if [ -n "$(d_barename "$f")" ]; then
    note "$f: is EXECUTED, so it takes a bare name (drop the suffix)"
  fi
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
  case $(d_binmode "$f") in
    unrunnable)
      note "$f: in bin/ with a shebang but NOT executable: it cannot run" ;;
    noshebang)
      note "$f: in bin/, executable, NO shebang: a guessed interpreter" ;;
  esac
done < "$FILES"

# --- 7. NO EM-DASHES, in prose, comments and docs alike ----------------------
# ALL THREE SPELLINGS, because the rule is about what a reader sees and they are
# indistinguishable on the page: the dash CHARACTER, the roff ASCII escape that
# renders as one, and the double hyphen standing in for one.
while IFS= read -r f; do
  d=$(d_dash "$f")
  [ -z "$d" ] || note "$f: contains a dash character used as punctuation"
  r=$(d_roff "$f")
  [ -z "$r" ] || note "$f: spells an em-dash as roff $r (renders as one)"
done < "$FILES"
out=$(d_dashdash "$FILES") || out='python3 failed to run the double-dash check'
[ -z "$out" ] || note "prose double-dashes (reword, or mark the line
  \`conventions: allow --\` with a reason):
$(printf '%s' "$out" | sed 's/^/    /')"

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
