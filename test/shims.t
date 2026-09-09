#!/bin/sh
# shims.t - the interception layer, and the usage text that describes it.
#
# A shim is a symlink named for an agent, pointing at the engine, in a
# directory the user puts FIRST on PATH. That is the whole mechanism by which
# typing `claude` reaches valet-key at all -- the pyenv/rbenv/asdf ritual, and
# the busybox multi-call trick on the other end. If shim management is wrong,
# nothing else in the tool ever runs.
#
# The properties worth pinning are mostly about NOT destroying things. The
# shims directory is a real directory on a real PATH, and these verbs run
# `ln -sfn` and `rm -f` inside it; a shim command that clobbers a real binary
# because someone typed a name valet-key does not know would be a bad way to
# find out.
#
# The last section is a drift check on `help`, whose text is the engine's own
# header comment sliced by line number. That is a good design -- one source of
# truth, so a verb cannot be added without the help growing a line -- and a
# fragile one, because the slice is a pair of numbers that nothing else
# validates. Pinning help against the dispatch table turns a silent
# truncation into a failing test.
#
# Nothing outside the scratch dir is touched.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init shims

VK=$HERE/bin/valet-key
ENGINE=$(readlink -f "$VK")
S=$T/shims
mkdir -p "$T/home"

E() {
  env -i PATH="$S:/usr/bin:/bin" HOME="$T/home" NO_COLOR=1 \
    VALET_KEY_CONFIG="$T/cfg" VALET_KEY_POOL_ROOT="$T/pool" \
    VALET_KEY_SHIMS_DIR="$S" "$@"
}

# --- the empty state is not an error ----------------------------------------
# Before anything is shimmed the directory does not exist. Listing and
# rehashing must still work: they are the two commands someone runs to find
# out what state they are in.
E sh "$VK" shims >/dev/null 2>&1 || fail "shims listing failed with no dir"
E sh "$VK" rehash >/dev/null 2>&1 || fail "rehash failed with no shims dir"

# --- create ------------------------------------------------------------------
E sh "$VK" shim claude >/dev/null 2>&1 || fail "shim claude failed"
[ -L "$S/claude" ] || fail "shim did not create a symlink"
[ "$(readlink -f "$S/claude")" = "$ENGINE" ] ||
  fail "the shim does not point at the engine"

# Idempotent: running it twice is running it once. Anything that provisions
# has to be safe to re-run, and `shim` is what an install script calls.
E sh "$VK" shim claude >/dev/null 2>&1 || fail "re-shimming failed"
[ "$(readlink -f "$S/claude")" = "$ENGINE" ] || fail "re-shim broke the link"

out=$(E sh "$VK" shims)
case $out in
  "claude -> "*) ;;
  *) fail "shims did not list the shim it just made: $out" ;;
esac

# Several at once, since that is how an installer calls it.
E sh "$VK" shim codex gemini >/dev/null 2>&1 || fail "multi-agent shim failed"
[ -L "$S/codex" ] && [ -L "$S/gemini" ] || fail "not every named shim was made"

# --- an unknown agent is refused, and changes nothing ------------------------
# There is no adapter, so there is nothing to route to; creating the symlink
# anyway would shadow whatever real binary has that name with an engine that
# can only die on it.
rc=0; E sh "$VK" shim nosuchagent >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "shimming an unknown agent did not fail (rc=$rc)"
[ -e "$S/nosuchagent" ] && fail "a refused shim was created anyway"

# ...and a refusal partway through a list does not silently skip the report.
rc=0; E sh "$VK" shim claude nosuchagent >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "a bad agent later in the list did not fail"

# --- remove -------------------------------------------------------------------
E sh "$VK" unshim gemini >/dev/null 2>&1 || fail "unshim failed"
[ -e "$S/gemini" ] && fail "unshim left the shim behind"

# Unshimming something that is not shimmed says so and carries on: an
# uninstaller runs over a list, and one absent entry is not a failure.
E sh "$VK" unshim gemini >/dev/null 2>&1 ||
  fail "unshim of an absent shim failed"

# A REAL FILE where a shim would be is left strictly alone. It is not ours: it
# is someone's actual binary, sitting in a directory we were pointed at, and
# `rm -f` on it would be unrecoverable.
printf '#!/bin/sh\n:\n' > "$S/precious"; chmod +x "$S/precious"
E sh "$VK" unshim precious >/dev/null 2>&1 || true
[ -f "$S/precious" ] && [ ! -L "$S/precious" ] ||
  fail "unshim deleted a real file that was not a shim"
# ...and it is not listed as a shim, because it is not one.
case $(E sh "$VK" shims) in
  *precious*) fail "a real file was listed as a shim" ;;
esac

# --- rehash: re-point shims after the engine moves ---------------------------
# The reason this verb exists: the shim is an absolute symlink, so moving the
# clone leaves every shim dangling, and a dangling shim is an agent command
# that has stopped existing.
ln -sfn /nonexistent/old/valet-key "$S/claude"
E sh "$VK" rehash >/dev/null 2>&1 || fail "rehash failed"
[ "$(readlink -f "$S/claude")" = "$ENGINE" ] ||
  fail "rehash did not re-point a stale shim"
# It only touches symlinks; the real file beside them survives.
[ -f "$S/precious" ] && [ ! -L "$S/precious" ] ||
  fail "rehash overwrote a real file"

# --- init / shims-dir: the two things a shell profile needs ------------------
[ "$(E sh "$VK" shims-dir)" = "$S" ] || fail "shims-dir printed the wrong path"
out=$(E sh "$VK" init)
[ "$out" = "export PATH=\"$S:\$PATH\"" ] ||
  fail "init did not print an eval-able PATH line: $out"
# It has to actually work when eval'd -- that is the documented usage.
got=$(E sh -c "eval \"\$(sh '$VK' init)\"; printf '%s' \"\${PATH%%:*}\"")
[ "$got" = "$S" ] || fail "eval \"\$(valet-key init)\" did not lead PATH: $got"

# --- usage text vs the dispatch table ----------------------------------------
# `help` is the header comment, sliced by line number. Every verb the engine
# dispatches on must appear in that slice, or someone reading the help has
# been told the tool is smaller than it is -- and the slice is what silently
# stops covering the file when a verb is added at the bottom.
help=$(E sh "$VK" help)
[ -n "$help" ] || fail "help printed nothing"
verbs=$(sed -n '/^_v=\${1:-}/,/^esac/p' "$VK" |
        sed -n 's/^  \([a-z][a-z-]*\)).*/\1/p')
[ -n "$verbs" ] || fail "could not read the dispatch table from bin/valet-key"
for v in $verbs; do
  case $help in
    *"valet-key $v"*) ;;
    *) fail "help does not document the '$v' verb" ;;
  esac
done

# The slice must also reach the END of the header prose. A range that stops
# short truncates without any sign of it: the last thing printed simply is
# not the last thing written.
tailwant=$(sed -n '/^set -eu$/=' "$VK" | head -1)
tailwant=$(sed -n "$((tailwant - 1))p" "$VK" | sed 's/^# \{0,1\}//')
case $help in
  *"$tailwant"*) ;;
  *) fail "help is truncated; it never reaches: $tailwant" ;;
esac

# The three no-argument spellings are the same text.
[ "$(E sh "$VK")" = "$help" ] || fail "bare invocation differs from help"
[ "$(E sh "$VK" --help)" = "$help" ] || fail "--help differs from help"
[ "$(E sh "$VK" -h)" = "$help" ] || fail "-h differs from help"

# An unknown verb is a loud failure that points at help, not a silent no-op.
rc=0; err=$(E sh "$VK" nosuchverb 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "an unknown verb did not exit 1 (rc=$rc)"
case $err in
  *"unknown command"*"help"*) ;;
  *) fail "an unknown verb did not point at help: $err" ;;
esac

pass
