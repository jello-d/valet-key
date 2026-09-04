#!/bin/sh
# doctor-context.t - doctor's check on the OPTIONAL context hook.
#
# valet-key owns this question because it declared the seam, and because both
# of the seam's failure modes are SILENT BY DESIGN: resolve reads a non-zero
# exit as "I cannot tell" and quietly falls back to the directory rule, while
# guard reads exit 2 as "warn, then proceed". So a hook broken by its provider
# renaming a verb keeps "working" -- nothing errors -- while whatever it was
# enforcing has stopped. That is not hypothetical; it happened.
#
# Every check here is GENERIC: it asks only what the contract promises, and
# names no provider. Nothing outside the scratch dir is touched.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init doctor-context

VK=$HERE/bin/valet-key
mkdir -p "$T/cfg"

doc() {
  VALET_KEY_CONFIG="$T/cfg" NO_COLOR=1 \
    sh "$VK" doctor 2>&1 | sed -n '/context hook/,/^$/p'
}
hook() { printf '%s\n' "$1" > "$T/cfg/context"; chmod +x "$T/cfg/context"; }

# --- no hook: not a problem, the built-in rule decides ----------------------
rm -f "$T/cfg/context"
case $(doc) in
  *"[IGNORE]"*) ;;
  *) fail "a missing hook should be IGNORE, not a finding" ;;
esac

# --- a healthy hook passes ---------------------------------------------------
hook '#!/bin/sh
case ${1:-} in resolve) echo personal ;; esac
exit 0'
out=$(doc)
case $out in *"[FAIL]"*) fail "a healthy hook was flagged: $out" ;; esac
case $out in *"answers resolve"*) ;; *) fail "no resolve verdict: $out" ;; esac
case $out in *"answers guard"*)   ;; *) fail "no guard verdict: $out" ;; esac

# --- THE case: the hook's provider fails, so the hook complains -------------
# resolve discards stderr and falls back, so this is invisible in normal use.
# A hook that ANSWERS is quiet; noise on stderr is the signal.
hook '#!/bin/sh
echo "provider: that verb is retired" >&2
exit 1'
case $(doc) in
  *"[FAIL]"*"writes to stderr"*) ;;
  *) fail "a complaining hook was not flagged: $(doc)" ;;
esac

# --- a hook that cannot even run: 127 reads as REFUSE ----------------------
hook '#!/bin/sh
exec definitely-not-a-real-command "$@"'
case $(doc) in
  *"guard exited 127"*) ;;
  *) fail "an unrunnable guard was not flagged: $(doc)" ;;
esac

# --- a hook returning a name that cannot be used ---------------------------
# The name becomes a directory component, so this is not a style complaint.
hook '#!/bin/sh
case ${1:-} in resolve) echo ../../etc ;; esac
exit 0'
case $(doc) in
  *"unusable profile"*) ;;
  *) fail "an unusable profile name was not flagged: $(doc)" ;;
esac

# --- a hook that is not executable ------------------------------------------
printf '#!/bin/sh\nexit 0\n' > "$T/cfg/context"; chmod -x "$T/cfg/context"
case $(doc) in
  *"not executable"*) ;;
  *) fail "a non-executable hook was not flagged: $(doc)" ;;
esac
chmod +x "$T/cfg/context"

# --- and doctor names no particular provider -------------------------------
# The whole point of this check living here: valet-key knows it has a seam, not
# who fills it.
hook '#!/bin/sh
exit 0'
case $(doc) in
  *severance*|*tackup*|*mux*) fail "doctor's context check names a provider" ;;
esac

pass
