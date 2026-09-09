#!/bin/sh
# doctor-hooks.t - doctor's check on the OPTIONAL hook seams.
#
# valet-key owns this question because it declared the seams, and because
# every one of their failure modes is SILENT BY DESIGN: selection reads a
# non-zero exit as "I cannot tell" and quietly falls back to the directory
# rule, veto reads exit 2 as "warn, then proceed", and a file without the
# executable bit is skipped without a word. So a hook broken by its provider
# renaming a verb keeps "working" -- nothing errors -- while whatever it was
# enforcing has stopped. That is not hypothetical; it happened.
#
# Every check here is GENERIC: it asks only what the contract promises, and
# names no provider. Nothing outside the scratch dir is touched.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init doctor-hooks

VK=$HERE/bin/valet-key
mkdir -p "$T/cfg/hooks/profile.d" "$T/cfg/hooks/guard.d"
PD=$T/cfg/hooks/profile.d
GD=$T/cfg/hooks/guard.d

# doctor's hooks section only. Everything is pointed into the scratch dir --
# doctor is read-only, but a test whose output depends on the box's real pool
# and real ~/.claude is a test that reports on the wrong machine.
doc() {
  env -i PATH="$PATH" HOME="$T/home" NO_COLOR=1 \
    VALET_KEY_CONFIG="$T/cfg" VALET_KEY_POOL_ROOT="$T/pool" \
    VALET_KEY_SHIMS_DIR="$T/shims" \
    sh "$VK" doctor 2>&1 | sed -n '/^hooks/,/^$/p'
}
mkhook() { printf '%s\n' "$2" > "$1"; chmod +x "$1"; }

# Drives the real resolve seam, to check an example in the LAUNCH path rather
# than only through doctor's inspection of it.
_fns=$(sed -n '/^valid_profile() {/,/^}/p;
               /^here_dir() {/,/^}/p;/^resolve_profile() {/,/^}/p' "$VK")
drive_resolve() {
  ( cd "$T" && env VALET_KEY_CONFIG="$T/cfg" sh -c "
      set -eu
      DEFAULT_PROFILE=personal
      VALET_KEY_CONFIG=\$VALET_KEY_CONFIG
      VALET_KEY_HOOKS=\$VALET_KEY_CONFIG/hooks
      $_fns
      resolve_profile" ) 2>/dev/null
}

# --- no hooks: not a problem, the built-in rule decides --------------------
case $(doc) in
  *"[IGNORE]"*) ;;
  *) fail "no hooks should be IGNORE, not a finding" ;;
esac

# --- healthy hooks pass ------------------------------------------------------
mkhook "$PD/50-sel" '#!/bin/sh
echo personal'
mkhook "$GD/50-ok" '#!/bin/sh
exit 0'
out=$(doc)
case $out in *"[FAIL]"*) fail "healthy hooks were flagged: $out" ;; esac
case $out in
  *"profile.d/50-sel answers"*) ;;
  *) fail "no selector verdict: $out" ;;
esac
case $out in *"guard.d/50-ok allows"*) ;; *) fail "no guard verdict" ;; esac

# --- THE case: a hook whose provider fails, so the hook complains ----------
# Selection discards stderr and moves to the next hook, so this is invisible.
# A hook that ANSWERS is quiet; noise on stderr is the signal.
mkhook "$PD/50-sel" '#!/bin/sh
echo "provider: that verb is retired" >&2
exit 1'
case $(doc) in
  *"[FAIL]"*"writes to stderr"*) ;;
  *) fail "a complaining selector was not flagged: $(doc)" ;;
esac

# --- a guard that cannot run: counts as a refusal, so say so ---------------
mkhook "$PD/50-sel" '#!/bin/sh
echo personal'
mkhook "$GD/50-ok" '#!/bin/sh
exec definitely-not-a-real-command'
case $(doc) in
  *"[FAIL]"*"exited 127"*) ;;
  *) fail "an unrunnable guard was not flagged: $(doc)" ;;
esac

# --- a selector returning a name that cannot be used -----------------------
mkhook "$GD/50-ok" '#!/bin/sh
exit 0'
mkhook "$PD/50-sel" '#!/bin/sh
echo ../../etc'
case $(doc) in
  *"unusable profile"*) ;;
  *) fail "an unusable profile name was not flagged: $(doc)" ;;
esac

# --- a hook nobody remembered to chmod +x ----------------------------------
# The most reachable version of this seam's worst state: the file is there,
# it is correct, and it has never once run. Both seams skip a file without the
# executable bit -- and without this check doctor would report "no hooks" over
# the top of a guard someone installed to refuse things.
mkhook "$PD/50-sel" '#!/bin/sh
echo personal'
printf '#!/bin/sh\nexit 1\n' > "$GD/60-forgot"      # deliberately not +x
case $(doc) in
  *"[FAIL]"*"60-forgot is not executable"*) ;;
  *) fail "a non-executable hook was silently ignored: $(doc)" ;;
esac
case $(doc) in
  *"chmod +x"*) ;;
  *) fail "the non-executable hook came with no fix: $(doc)" ;;
esac
chmod +x "$GD/60-forgot"
case $(doc) in
  *"[FAIL]"*) fail "chmod +x did not clear the finding: $(doc)" ;;
esac
rm -f "$GD/60-forgot"

# ...and it is reported even when it is the ONLY thing in the hooks dirs,
# which is the case where "no hooks" would otherwise be printed.
rm -f "$PD"/* "$GD"/*
printf '#!/bin/sh\nexit 1\n' > "$PD/50-forgot"
out=$(doc)
case $out in
  *"50-forgot is not executable"*) ;;
  *) fail "a lone non-executable hook was not reported: $out" ;;
esac
case $out in
  *"no hooks"*) fail "a present-but-unreadable hook was reported as none" ;;
esac
rm -f "$PD"/*

# --- a file at the RETIRED single-hook path is reported --------------------
# Silently ignoring it would leave someone believing a boundary is enforced
# when nothing is reading it. That is this seam's worst failure.
mkhook "$PD/50-sel" '#!/bin/sh
echo personal'
printf '#!/bin/sh\nexit 0\n' > "$T/cfg/context"; chmod +x "$T/cfg/context"
case $(doc) in
  *"no longer read"*) ;;
  *) fail "a leftover single-file hook was silently ignored: $(doc)" ;;
esac
rm -f "$T/cfg/context"

# --- doctor names no particular provider -----------------------------------
# The whole point of this check living here: valet-key knows it has seams, not
# who fills them.
case $(doc) in
  *severance*|*tackup*|*mux*) fail "doctor's hook check names a provider" ;;
esac

# --- the SHIPPED examples must satisfy the contract they document ----------
# An example that no longer works is worse than none: it teaches the wrong
# shape, and nobody runs it to find out. These are the files share/hooks/
# tells people to copy.
for _ex in "$HERE"/share/hooks/profile.d/* "$HERE"/share/hooks/guard.d/*; do
  [ -f "$_ex" ] || continue
  [ -x "$_ex" ] || fail "shipped example is not executable: $_ex"
  dash -n "$_ex" || fail "shipped example is not valid sh: $_ex"
done

rm -f "$PD"/* "$GD"/*
cp "$HERE"/share/hooks/profile.d/* "$PD/"
cp "$HERE"/share/hooks/guard.d/* "$GD/"
chmod +x "$PD"/* "$GD"/*
out=$(doc)
case $out in
  *"[FAIL]"*) fail "a shipped example fails doctor's own checks: $out" ;;
esac

# They must also RUN cleanly in the launch path, not merely pass inspection:
# a selector that abstains and a guard that allows leave the default in place.
[ "$(drive_resolve)" = personal ] ||
  fail "shipped examples changed the resolved profile on this box"

# ...and none of them names severance. The seam is not about one integration,
# and an example that assumed one would teach exactly the wrong lesson.
grep -rli severance "$HERE/share/hooks" >/dev/null 2>&1 &&
  fail "a shipped example names a specific integration"

pass
