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
# It enforces the "Code style" section of ~/src/shared-notes/_common.md, and
# since 2026-10-04 the "package tree is FHS" section too (rules 9 and 10). That
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

# THE REPO IS THE ONE THIS FILE IS VENDORED INTO, asked from THIS FILE'S OWN
# LOCATION and never from the caller's cwd. `git rev-parse` with no -C answers
# about the current directory, which is the caller's, and that is wrong in two
# directions:
#   outside any repo    -> "not a git repo", so the check cannot run at all
#   inside ANOTHER repo -> it silently audits THAT repo and reports clean
# The second is the dangerous one, because nothing in the output says which
# tree was read. MEASURED 2026-10-02 running a deployed clone's suite from two
# boxes: from $HOME it failed outright, and from a dev checkout of the same
# project it audited the CHECKOUT and passed, with the clone never read. Same
# commit, same files, opposite verdicts, and the passing one was the lie.
# A vendored checker must be anchored to what it is vendored beside.
# shellcheck disable=SC1007  # `CDPATH= cd` neutralises a set CDPATH for ONE
# command and is the correct idiom; shellcheck reads it as an empty assignment.
# This directive is NOT optional decoration: a repo whose lint shellchecks
# every *.t lints this file too, and without it that repo's whole suite is RED
# for a line it did not write and must not edit. bootique was, since the
# 2026-10-02 anchor fix landed here. Every other caller of this idiom in the
# fleet already carries the same disable.
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null) || ROOT=
[ -n "$ROOT" ] || { echo "FAIL conventions: $HERE is not in a git repo" >&2
  exit 1; }
EXEMPT=$HERE/conventions.exempt
cd "$ROOT"

# THE PACKAGE'S OWN NAME, the subject of rule 10. setup.sh's PKG= when there is
# one, because that is what the installer itself uses; otherwise the repo
# directory, which is what a clone is called. Never empty, so rule 10 always has
# something to compare against rather than silently matching everything.
PKGNAME=$(sed -n 's/^PKG=\([A-Za-z0-9_.-]*\).*/\1/p' setup.sh 2>/dev/null \
          | head -1)
[ -n "$PKGNAME" ] || PKGNAME=${ROOT##*/}

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
# A LITERAL TAB IN A VARIABLE, because the two list-based detectors emit
# tab-separated records and `IFS='<tab>'` written inline is invisible: an
# editor that trims trailing whitespace, or a copy through a terminal, turns
# it into an empty IFS and every record then splits on whitespace, putting a
# path with a space in it into two fields.
TABCH=$(printf '\t')
# THE LITERAL LIST, built once and reused by the trap below and by the wider
# one at the self-test section. Same rule as that one: expand now, not at fire
# time. `mktemp` with no template cannot answer a path with a quote in it, and
# the refusal is cheaper than reasoning about it again later.
case $FILES in
('' | *\'*) echo "conventions: refusing an unusable temp file: [$FILES]" >&2
  exit 1 ;;
esac
CLEANF="'$FILES' '$FILES.sh' '$FILES.bash' '$FILES.py' '$FILES.cols'"
CLEANF="$CLEANF '$FILES.dash'"
# shellcheck disable=SC2064  # EXPANDING NOW IS THE POINT: see $SELF's trap.
trap "rm -f $CLEANF" EXIT
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
# COUNTED AND REPORTED, because rules 9 and 10 are vacuous in a repo with none
# of the three directories and a bare `ok` cannot be told from a rule that
# stopped matching. mux's lint set shrank from 149 files to 129 unnoticed for
# exactly that reason; a pass line that states what it measured can be caught.
NTREE=$(grep -cE '^(bin|lib|libexec)/' "$FILES" || :)

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
# python3, NOT `awk 'length > 80'`, AND THE REASON IS A MEASUREMENT. gawk in a
# UTF-8 locale counts CHARACTERS; BSD awk counts BYTES, and macOS ships the
# latter. So the identical tree was clean on Linux and had seven violations on
# a Mac, none of them real:
#
#     README.md:90                     76 chars     154 bytes
#     bin/mux:1391                     79 chars      81 bytes
#     libexec/mux-agent-state-render   78 chars      84 bytes
#
# The comment above this used to say "awk counts CHARACTERS, which is what the
# limit means", which was true of the author's awk and false of half the fleet:
# a portability claim with no check behind it.
#
# CHARACTERS IS THE RIGHT READING and bytes is not close. That README line is a
# table of glyphs, so passing a byte limit would mean deleting content to
# satisfy a measurement nobody makes. (Display WIDTH is righter still, since a
# glyph like U+26AB occupies two cells, and it is not worth a wcwidth table
# here: characters is what the fleet has always enforced.)
#
# THE PORTABLE awk WAS TRIED AND REJECTED: counting bytes that are not UTF-8
# continuation bytes works on a byte-based awk and needs a `[\200-\277]`
# class, which gawk in UTF-8 reads as the CODEPOINTS U+0080..U+00BF instead,
# so a line containing `\u00b7` MIDDLE DOT undercounts. There is one in this
# very tree (libexec/mux-agent-state-render), so that is a live bug and not a
# hypothetical one.
#
# IT TAKES THE FILE LIST, one process for the whole tree, which is the pattern
# rules 3 and 7's double-dash half already use. Per-file it would be 187 python
# startups and about 3s added to every suite run and every pre-commit hook.
d_cols() {   # <file-list> -> "<path>TAB<line numbers>" per offending file
  python3 - "$1" <<'PYCOLS'
import sys
out = []
for path in open(sys.argv[1]).read().split():
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            over = [str(n) for n, line in enumerate(fh, 1)
                    if len(line.rstrip("\n")) > 80]
    except OSError:
        continue
    if over:
        out.append("%s\t%s" % (path, " ".join(over)))
print("\n".join(out))
PYCOLS
}
# awk, NOT `grep -P`, AND THAT IS A PORTABILITY FIX WITH A HISTORY: BSD grep
# has no -P at all, so on macOS this printed a usage block to the /dev/null
# below, returned nothing, and the count read as 0 tabs. That is the exact
# degradation the self-test section predicts in its own comment, and it took a
# macOS CI runner to meet it. The tab is built with sprintf rather than written
# as a backslash-t, because an escape inside a regex is the implementation's
# business and a literal tab in a source line is an editor's.
d_tabs() {   # <file> -> count of TAB-indented lines (0 when clean)
  awk 'BEGIN { t = sprintf("%c", 9) }
       $0 ~ "^ *" t { n++ }
       END { print n + 0 }' "$1" 2>/dev/null || true
}
# The banned set is every dash a writer reaches for INSTEAD of punctuation, not
# only the two that turned up first: figure dash, en, em, horizontal bar, the
# two- and three-em dashes, the non-breaking hyphen, the fullwidth hyphen, the
# MINUS SIGN (identical to an em-dash in a comment) and the SOFT HYPHEN,
# invisible and so the worst of them. Measured across all 15 repos: no text file
# holds any of these beyond U+2014/U+2013, so widening costs nothing today and
# closes the hole before someone pastes one in.
# python3, NOT `grep -P`, for the same reason d_tabs moved to awk: no BSD grep
# has PCRE, so rule 7 reported EVERY file clean on macOS. python3 is not a new
# dependency (rule 3 and the prose scan below already need it) and it is the
# only tool here that can name a codepoint without the pattern depending on
# the locale. An undecodable byte is REPLACED rather than raising: a file this
# cannot decode is not a file with an em-dash in it, and the self-test is what
# catches this going silent in either direction.
d_dash() {   # <file-list> -> "<path>TAB<char>" per offending file
  python3 - "$1" <<'PYDASH'
import sys
BANNED = (
    "\u00ad"                                    # SOFT HYPHEN: invisible,
                                                # so the worst of them
    "\u2010\u2011\u2012\u2013\u2014\u2015"  # hyphen .. horizontal bar
    "\u2212"                                    # MINUS SIGN: identical to an
                                                # em-dash in a comment
    "\u2e3a\u2e3b"                             # two- and three-em dashes
    "\uff0d"                                    # FULLWIDTH HYPHEN-MINUS
)
out = []
for path in open(sys.argv[1]).read().split():
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for ch in text:
        if ch in BANNED:
            # THE CODEPOINT, NOT THE CHARACTER. Three of the eleven are
            # invisible or near-invisible (U+00AD SOFT HYPHEN above all), so
            # echoing the byte back produces a message with a hole in it:
            # "contains the dash character  used as punctuation". Naming it
            # also keeps this checker's own output free of the thing it bans.
            out.append("%s\tU+%04X" % (path, ord(ch)))
            break
print("\n".join(out))
PYDASH
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
# RULES 9 AND 10 BELONG WITH 4, 5 AND 6 and are numbered after 8 only to spare
# a vendored file the churn of renumbering. Those three ask about one FILE (its
# name, its mode, its shebang); these two ask where it SITS, which is the half
# that was unenforced: rule 4 refuses an executable *_lib and says nothing about
# a *_lib sitting in libexec/, which is exactly the state nine repos were in.
#
# d_tree IS PURE: it takes the exec bit as a WORD rather than stat'ing the path,
# so every one of its five answers is provable in both directions without a
# fixture on disk, and the self-test can assert the exact WORD. That matters
# more here than for 4/5/6, because this detector returns a VOCABULARY and the
# rule below dispatches on it: a detector answering the wrong word would pass an
# is-it-empty check, match no case arm, and report nothing at all.
#
# ANCHORED AT THE REPO ROOT, deliberately. `lib/*` and not `*/lib/*`, because
# tackup's link/lib is a PUBLISHED tree whose files are uniformly 0755 by a
# written decision (its CLAUDE.md says so, and the reason is that telling a
# sourced helper from an exec'd one by inspection is a losing game there). An
# unanchored pattern would fail that repo on every file it ships.
d_tree() {   # <relpath> <exec: x|-> -> one word for a misplacement, else empty
  case $1 in
  lib/*)
    if [ "$2" = x ]; then echo lib-exec; return 0; fi
    case ${1#lib/} in
      */*) ;;                        # a subdirectory already states the role
      *_lib|*_lib.py|*.py) ;;        # carries its own marker
      *) echo lib-unmarked ;;
    esac ;;
  libexec/*)
    case $1 in *_lib|*_lib.py) echo lib-misplaced; return 0 ;; esac
    if [ "$2" != x ]; then echo libexec-noexec; fi ;;
  bin/*)
    case $1 in *_lib|*_lib.py) echo lib-misplaced ;; esac ;;
  esac
}
d_double() {   # <relpath> <pkg> -> non-empty when a dir re-names the package
  [ -n "${2:-}" ] || return 0
  case $1 in
    "lib/$2"/*|"libexec/$2"/*) echo doubled ;;
  esac
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
# ANCHORED to a command POSITION rather than to any preceding whitespace.
# `install`, `set`, `test`, `env`, `find`, `dd` and `mount` are ordinary
# English, and with 40 characters of slack after any of them the loose form read
# `systemctl -- so there is NO sudo` as an end-of-options marker. A real marker
# sits at the START of a command, which is what this asks; the self-test's
# `cd --` fixture passes for exactly that reason.
# A QUOTE opens a command position too, because a quoted command TEMPLATE is
# still a command: `"kubectl exec %h -- %q"` is kubectl's own separator, and a
# python STRING token arrives with its delimiters attached, so without this the
# anchor can never see the command that starts the string. So does a LITERAL
# `\n`, which inside a quoted string is a newline and therefore a command
# separator: a generated stub written as `'#!/bin/sh\nprintf -- "..."'` puts a
# real end-of-options marker at the start of its second line.
ARGM  = re.compile(r'(^|[;&|(`"\']|\\n)\s*(cd|set|eval|exec|printf|command|'
                   r'readlink|'
                   r'pgrep|pkill|xargs|install|chown|chmod|rm|cp|mv|grep|sed|'
                   r'awk|find|git|echo|tar|dd|env|test|parted|sgdisk|mkfs|'
                   r'mount|umount|dpkg|apt-get|systemctl|kubectl|ssh|sudo|'
                   r'logger|\[)\b[^`]{0,40}--(\s|$)')

def visible(line):
    # An ODD backtick count means one of them is UNBALANCED, which is routine
    # at 80 columns, where an inline code span wrapping across lines leaves one
    # backtick on each. Keeping the even-indexed halves then silently EATS the
    # rest of the line, so an unmatched backtick is the literal character it is.
    parts = line.split('`')
    if len(parts) % 2 == 0:
        return line
    return ''.join(p for k, p in enumerate(parts) if k % 2 == 0)

def banner(line):
    t = line.strip().lstrip('#').strip()
    return len(t) > 3 and t.startswith('--') and t.endswith('--')

def lang(path, txt):
    """This file's LANGUAGE, by suffix and then by SHEBANG. The shebang half is
    load-bearing rather than a nicety: the house rule gives an EXECUTED file a
    BARE NAME, so every python COMMAND in these trees lacks a .py, was read as
    shell, and had its docstrings scanned by nothing at all."""
    if path.endswith('.py'):
        return 'py'
    if re.search(r'\.[1-8]$', path) or '/man/' in path:
        return 'roff'
    if path.endswith('.md'):
        return 'md'
    if re.search(r'\.(css|jsonc|c|h|cc|cpp|hpp|rs|go|js|ts)$', path):
        return 'cfam'
    if re.match(r'^#!.*\bpython3?\b', txt.split('\n', 1)[0]):
        return 'py'
    return 'sh'

def prose_py(txt):
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

def prose_md(lines):
    got, fence = {}, False
    for n, l in enumerate(lines, 1):
        if l.strip().startswith('```'):
            fence = not fence
            continue
        if fence or re.match(r'^\s{4,}\S', l):
            continue
        got[n] = l
    return got

def prose_cfam(lines):
    """C-family COMMENTS, which the `#` branch can never see: a .css or .jsonc
    file carries its prose in `/* */` and `//` and has no `#` at all, so it was
    scanned by nothing. 32 of tackup's violations were waybar comments."""
    got, block = {}, False
    for n, l in enumerate(lines, 1):
        s = l.strip()
        if block:
            got[n] = l
            if '*/' in s:
                block = False
            continue
        if s.startswith('/*'):
            got[n] = l
            if '*/' not in s[2:]:
                block = True
            continue
        m = re.search(r'//(.*)$', l)
        if m:
            got[n] = m.group(1)
    return got

def prose_sh(lines):
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
            # `a or b`, NEVER `a if a is not None else b`: re.findall yields
            # the EMPTY STRING for a group that did not participate, not None,
            # so the old form picked the empty double-quote group for every
            # SINGLE-quoted string and this whole branch only ever saw the
            # double-quoted ones. In shell that is most printed text.
            segs = [(a or b) for a, b in
                    re.findall(r'"([^"]*)"|\'([^\']*)\'', l)]
            # A segment that IS the token, `--` and nothing else, is syntax
            # whatever it is doing: an end-of-options marker, or a literal pair
            # handed to a command as data (`tr ':.' '--'`). It cannot be prose,
            # because prose needs words either side and this segment has none.
            keep = [x for x in segs
                    if not banner(x) and x.strip() != '--']
            if keep:
                got[n] = ' | '.join(keep)
    return got

def prose_lines(path):
    """{lineno: text} for the lines that are PROSE in this file's language."""
    try:
        txt = open(path, encoding='utf-8', errors='replace').read()
    except Exception:
        return {}
    kind = lang(path, txt)
    if kind == 'py':
        return prose_py(txt)
    lines = txt.splitlines()
    if kind == 'md':
        return prose_md(lines)
    if kind == 'cfam':
        return prose_cfam(lines)
    if kind == 'roff':
        # ROFF: a line opening with . or ' is a CONTROL line (a macro; `.B`
        # legitimately bolds a literal double hyphen), and everything else is
        # body PROSE, which the `#`-comment branch would never have seen.
        # Measured across 9 man pages: zero violations, so this was free.
        return {n: l for n, l in enumerate(lines, 1)
                if l[:1] not in ('.', "'")}
    return prose_sh(lines)

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
# rules 2, 3 and 7 need python3 or awk, and rule 8 needs dash and bash. EVERY
# ONE OF THOSE DEGRADED TO SILENCE. Measured, before this section existed:
#
#   python3 hidden      a planted 2-space Python indent -> rc=0, "10 python"
#   grep without -P     a tabbed line -> count empty -> read as 0 tabs
#   grep without -P     a real em-dash -> rule 7 never fires
#   dash absent         a file that does not parse -> reported clean
#
# AND THE MIDDLE TWO WERE NOT HYPOTHETICAL. They shipped, and a macOS CI runner
# met them on 2026-09-30: BSD grep has no -P, so rules 2 and 7 were enforcing
# NOTHING on every Mac while this file reported its usual pass everywhere else.
# THIS SECTION IS THE ONLY REASON ANYONE FOUND OUT, which is the argument for
# proving a detector rather than trusting it. Both moved off PCRE (awk and
# python3); the rows above are kept as the record of what was measured.
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
# --- `rm -rf` NEVER RUNS WITH A DEFERRED EXPANSION --------------------------
# THE STANDING RULE in ~/src/CLAUDE.md, Equal-weight rules: the value is
# expanded FIRST, while it can still be checked, and the LITERAL is written
# down so the exact command can be read before it runs.
#
# A trap is the sharpest case of it, because `trap 'rm -rf "$SELF"' EXIT`
# defers the expansion to FIRE TIME: the shell is already exiting, often on an
# error path, and whatever the variable holds by then is what goes. THAT IS
# NOT A HYPOTHETICAL HERE. mux's test harness had the identical shape and
# DELETED ITS OWN REPOSITORY on 2026-09-30, because a canonicalisation
# (`cd -- "$(mktemp -d)" && pwd -P`) turns an EMPTY mktemp answer into the
# CURRENT DIRECTORY, and `mktemp` answering empty needs nothing more exotic
# than a stale TMPDIR. This file is vendored into fourteen repos, so it was
# fourteen copies of that shape.
#
# So: verify, then bake the literal in. `trap` then PRINTS exactly what will
# run, and no later assignment to SELF or FILES can move the target.
case $SELF in
('' | *\'*) echo "conventions: refusing an unusable scratch dir: [$SELF]" >&2
  exit 1 ;;
esac
[ -d "$SELF" ] && [ "$SELF" != "$PWD" ] && [ "$SELF" != / ] || {
  echo "conventions: refusing [$SELF] as the scratch dir: not a directory," >&2
  echo "conventions: or it is the current directory, or /." >&2
  exit 1; }
# ONE trap covering both, replacing the corpus trap above rather than sitting
# beside it: POSIX sh has no trap stack, so a second `trap ... EXIT` would
# silently discard the first and leak $FILES on every run.
# shellcheck disable=SC2064  # EXPANDING NOW IS THE POINT: see above.
trap "rm -f $CLEANF; rm -rf '$SELF'" EXIT
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

# A VOCABULARY NEEDS ITS WORDS PROVEN. `prove` asks only whether a detector
# fired, which is the whole question for rules 1 to 8: their detectors answer
# hit-or-not. d_tree answers one of FIVE words and rule 9 dispatches on which,
# so a detector returning the wrong word fires, passes `prove`, matches no case
# arm, and reports nothing. This asserts the exact word instead.
prove_word() {   # <name> <expected-word> <finding>
  if [ "$3" = "$2" ]; then NPROVEN=$((NPROVEN + 1)); return; fi
  note "SELF-TEST: the $1 detector answered '$3' where '$2' was expected, so
  rule 9's case below matches nothing and the misplacement goes unreported"
}

# printf, NOT awk: `awk 'BEGIN{..}END{..}'` with no file argument reads STDIN
# and waits forever, which hung this section the first time it ran. A test that
# BLOCKS is worse than one that fails, so nothing here reads stdin.
printf '%090d\n' 0 > "$SELF/long"
printf 'short line\n' > "$SELF/short"
printf '%s\n' "$SELF/long"  > "$SELF/collist.bad"
printf '%s\n' "$SELF/short" > "$SELF/collist.good"
prove 1-columns y "$(d_cols "$SELF/collist.bad")"
prove 1-columns n "$(d_cols "$SELF/collist.good")"
# A MULTI-BYTE LINE THAT IS UNDER THE LIMIT, which is the case that was
# broken: 40 copies of a 3-byte character is 40 characters and 120 bytes, so
# a byte-counting detector calls it a violation and a correct one does not.
# Proven as a CLEAN sample, because the failure here was a FALSE positive.
awk 'BEGIN {
       s = ""
       while (length(s) < 40) s = s sprintf("%c%c%c", 226, 152, 133)
       print s
     }' > "$SELF/wide"
printf '%s\n' "$SELF/wide" > "$SELF/collist.wide"
prove 1-columns n "$(d_cols "$SELF/collist.wide")"

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
printf '%s\n' "$SELF/dashy" > "$SELF/dashlist.bad"
printf '%s\n' "$SELF/clean" > "$SELF/dashlist.good"
prove 7-dashes y "$(d_dash "$SELF/dashlist.bad")"
prove 7-dashes n "$(d_dash "$SELF/dashlist.good")"

# Built with printf from the byte sequence so this file holds no banned dash
# itself, which would make it fail its own rule 7.
printf 'roff \134(em here\n' > "$SELF/roffy"
printf 'spelled with a plain - hyphen\n' > "$SELF/roffclean"
prove 7-roff y "$(d_roff "$SELF/roffy")"
prove 7-roff n "$(d_roff "$SELF/roffclean")"

# The double-dash detector, over a LIST like the real rule takes. Four base
# samples: prose must fire; an argument marker, a divider and an opted-out line
# must not. The opt-out is proven because an escape hatch nobody tests is one
# that silently stops working, and then every marked line is unchecked.
# conventions: allow -- every fixture below PLANTS the violation it proves, so
# this paragraph opts out of the rule it tests. The marker must sit ENTIRELY on
# one line: the pattern wants `conventions:` and the dashes together, so
# wrapping it across two lines suppresses nothing and reports the marker
# itself. The blank line after the last prove ends the suppression.
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
# FIVE MORE, one per gap that made this rule report a clean tree over 183 real
# violations in sixteen repos (2026-10-05). Each is named for its gap, so a
# regression says which half broke rather than just "dashdash". The backtick
# fixture builds its backtick from \140 so THIS file holds none on that line:
# a literal one would block the argument-marker exclusion that keeps the line
# above from reading as a violation of itself.
printf '#!/usr/bin/env python3\n"""A clause -- and more."""\n' > "$SELF/dd-pyc"
printf '/* a clause -- and its continuation */\n'   > "$SELF/dd.css"
printf '# a \140span and then -- the rest\n'        > "$SELF/dd-tick.sh"
printf '# at install -- and the rest\n'             > "$SELF/dd-mid.sh"
printf 'printf %s\n' "'a clause -- and more\\n'"    > "$SELF/dd-sq.sh"
for _f in dd-pyc dd.css dd-tick.sh dd-mid.sh dd-sq.sh; do
  printf '%s\n' "$SELF/$_f" > "$SELF/ddlist.$_f"
done
prove 7-dd-shebang y "$(d_dashdash "$SELF/ddlist.dd-pyc")"
prove 7-dd-cfam    y "$(d_dashdash "$SELF/ddlist.dd.css")"
prove 7-dd-tick    y "$(d_dashdash "$SELF/ddlist.dd-tick.sh")"
prove 7-dd-midword y "$(d_dashdash "$SELF/ddlist.dd-mid.sh")"
prove 7-dd-squote  y "$(d_dashdash "$SELF/ddlist.dd-sq.sh")"

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

# RULE 9 IS PROVED BY WORD, every arm of the case below it, because the rule
# dispatches on which word comes back. No fixture on disk: d_tree is pure, so
# the exec bit is an argument and every combination is reachable.
prove_word 9-lib-exec       lib-exec       "$(d_tree lib/a_lib x)"
prove_word 9-lib-unmarked   lib-unmarked   "$(d_tree lib/plain -)"
prove_word 9-lib-misplaced  lib-misplaced  "$(d_tree libexec/a_lib x)"
prove_word 9-bin-misplaced  lib-misplaced  "$(d_tree bin/a_lib x)"
prove_word 9-libexec-noexec libexec-noexec "$(d_tree libexec/cmd -)"
# THE CLEAN CASES, and the three EXEMPTIONS the rule grants on purpose: a
# subdirectory of lib/ states the role itself, a language module suffix is a
# marker, and anything outside the three directories is not this rule's business
# (which is what spares tackup's link/lib, so that is asserted and not assumed).
prove 9-tree n "$(d_tree lib/a_lib -)"
prove 9-tree n "$(d_tree lib/adapters/claude -)"
prove 9-tree n "$(d_tree lib/module.py -)"
prove 9-tree n "$(d_tree libexec/cmd x)"
prove 9-tree n "$(d_tree bin/cmd x)"
prove 9-tree n "$(d_tree link/lib/helper x)"
prove 9-tree n "$(d_tree share/pkg/data.conf -)"

# RULE 10, both directions, and the empty-package guard: an unknown package name
# must match NOTHING rather than every path, which is the failure that would
# turn this rule into noise on the first repo whose setup.sh it cannot read.
prove 10-double y "$(d_double libexec/demo/cmd demo)"
prove 10-double y "$(d_double lib/demo/x_lib demo)"
prove 10-double n "$(d_double libexec/cmd demo)"
prove 10-double n "$(d_double libexec/demo/cmd '')"
prove 10-double n "$(d_double libexec/demolition/cmd demo)"


if [ -n "$bad" ]; then
  printf 'FAIL conventions (SELF-TEST):%s\n' "$bad" >&2
  echo >&2
  echo 'A detector above is not working, so NOTHING ELSE RAN: every rule' >&2
  echo 'below would report clean whether the tree is clean or not. Fix the' >&2
  echo 'tool (rules 2/3/7 need python3 or awk, rule 8 needs dash and' >&2
  echo 'bash) rather than reading the result.' >&2
  exit 1
fi

# --- 1. 80 COLUMNS, the hard rule --------------------------------------------
# CHARACTERS, not bytes: see d_cols, where the difference cost a Mac seven
# false findings. REDIRECTED TO A FILE RATHER THAN PIPED, because `note`
# appends to a shell VARIABLE and a pipeline runs its right-hand side in a
# SUBSHELL, so every finding would be discarded and the rule would report
# clean for a reason nothing on screen could explain.
d_cols "$FILES" > "$FILES.cols" \
  || note "python3 failed to run the column check"
while IFS="$TABCH" read -r f w; do
  [ -n "$f" ] || continue
  note "$f: over 80 columns at line(s): $w"
done < "$FILES.cols"

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
d_dash "$FILES" > "$FILES.dash" \
  || note "python3 failed to run the dash-character check"
while IFS="$TABCH" read -r f d; do
  [ -n "$f" ] || continue
  note "$f: contains $d, a dash character used as punctuation"
done < "$FILES.dash"
# THE ROFF HALF STAYS PER FILE: `grep -oE` is POSIX, so it works on either
# userland, and it names WHICH escape it found, which is the useful half of
# that message.
while IFS= read -r f; do
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

# --- 9. THE IMPLEMENTATION DIRECTORY SAYS LOADED OR EXECUTED -----------------
# FHS, and a single-source-of-truth rule rather than tidiness: lib/ is what a
# package SOURCES or imports, libexec/ what it EXECUTES and never puts on PATH.
# When the directory carries that, the name and the mode stop being the only
# signals and can no longer quietly disagree with each other.
#
# MEASURED, 2026-10-04: nine of the spun-out packages disagreed about this, the
# sharpest pair being muster's lib/ holding eleven sourced files while
# severance's libexec/ held eleven sourced files. Identical content, two names.
#
# A BINARY OR EXEMPT FILE NEVER REACHES HERE, because the corpus drops both
# above, so a compiled object under lib/ is not a finding and does not need an
# exemption to stay quiet.
while IFS= read -r f; do
  # `if`, not `[ ... ] && _x=x`: an AND-list is a trap in a loop body (see rule
  # 4) and the explicit form costs nothing.
  if [ -x "$f" ]; then _x=x; else _x=-; fi
  case $(d_tree "$f" "$_x") in
    lib-exec)
      note "$f: is in lib/, which is SOURCED, and is EXECUTABLE. The bit is a
  lie: running it does nothing useful." ;;
    lib-unmarked)
      note "$f: is in lib/ but carries no loadable marker (*_lib, or a language
  module suffix). A file in a SUBDIRECTORY of lib/ is fine, since the directory
  states the role; this one is at the top." ;;
    lib-misplaced)
      note "$f: is named as a sourced library but sits outside lib/. libexec/ is
  EXECUTED and bin/ is on PATH; a sourced library belongs in lib/." ;;
    libexec-noexec)
      note "$f: is in libexec/, which is EXECUTED, and is NOT executable. It
  resolves and then fails to run, which reads as a missing feature." ;;
  esac
done < "$FILES"

# --- 10. NEITHER DIRECTORY RE-NAMES ITS OWN PACKAGE --------------------------
# libexec/<pkg>/ is a SHARED-prefix vestige. When every package's helpers landed
# in one ~/.local/libexec, each needed a namespace of its own; once the prefix
# is package-private (a payload at ~/.local/share/<pkg>, or /opt/<pkg>) the name
# is simply written twice, as <payload>/libexec/hwdp/cmd was before flattening.
#
# NOT a guess about which prefix a package installs into: the doubling is wrong
# in a private prefix and unnecessary in a shared one, because a shared prefix
# namespaces by the <pkg> directory it already has.
while IFS= read -r f; do
  if [ -n "$(d_double "$f" "$PKGNAME")" ]; then
    note "$f: repeats the package name inside its own tree. Flatten it: the
  prefix already namespaces '$PKGNAME', so this writes the name twice."
  fi
done < "$FILES"

finish
pass "$N files, $(( $(wc -l < "$FILES.sh") + $(wc -l < "$FILES.bash") ))\
 shell, $(wc -l < "$FILES.py") python, $NTREE in bin/lib/libexec,\
 $NPROVEN detectors proven"
