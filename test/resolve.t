#!/bin/sh
# resolve.t - the resolve seam's contract: when is the context hook's answer
# authoritative, and when does valet-key fall back to its own directory rule?
#
# The distinction under test is between a hook that ANSWERED and one that
# COULD NOT. Exit 0 is authoritative even when the output is empty ("no
# special context here"); only a non-zero exit falls through to the matcher.
# Getting that wrong is not cosmetic: it is the difference between a broken
# integration surfacing and it silently re-enabling directory guessing.
#
# resolve_profile is extracted from bin/valet-key and driven directly, so the
# test exercises the real function rather than a copy of its logic. Nothing
# outside the scratch dir is read or written.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init resolve

VK=$HERE/bin/valet-key
mkdir -p "$T/cfg"

# Pull the seam out of the engine: valid_profile, here_dir, resolve_profile.
fns=$(sed -n '/^valid_profile() {/,/^}/p;/^here_dir() {/,/^}/p;
              /^resolve_profile() {/,/^}/p' "$VK")
[ -n "$fns" ] || fail "could not extract the resolve seam from bin/valet-key"

# Drive it with a scratch config and a known default. cd into T so the
# directory matcher has a stable, non-repo context to look at.
resolve() {
  ( cd "$T" && env VALET_KEY_CONFIG="$T/cfg" sh -c "
      set -eu
      DEFAULT_PROFILE=personal
      VALET_KEY_CONFIG=\$VALET_KEY_CONFIG
      $fns
      resolve_profile" ) 2>/dev/null
}
resolve_rc() {   # same, but report the status and let stderr through
  ( cd "$T" && env VALET_KEY_CONFIG="$T/cfg" sh -c "
      set -eu
      DEFAULT_PROFILE=personal
      VALET_KEY_CONFIG=\$VALET_KEY_CONFIG
      $fns
      resolve_profile" ) 2>&1
}

# hook <stdout> <exit>
hook() {
  { echo '#!/bin/sh'
    echo 'case "${1:-}" in'
    printf "  resolve) printf '%%s' \"%s\"; exit %s ;;\n" "$1" "$2"
    echo '  *) exit 0 ;;'
    echo 'esac'
  } > "$T/cfg/context"
  chmod +x "$T/cfg/context"
}

# --- no hook at all: the built-in rule, then the default ---------------------
rm -f "$T/cfg/context"
[ "$(resolve)" = personal ] || fail "no hook: want the default profile"

# --- exit 0 with a token: authoritative --------------------------------------
hook manifest 0
[ "$(resolve)" = manifest ] || fail "hook token ignored: got '$(resolve)'"

# --- exit 0 with EMPTY: also authoritative, and means the DEFAULT ------------
# The matcher must NOT run. A profiles file that would match everything proves
# it: if the fallthrough happened, the answer would be 'matched', not the
# default.
printf "matched %s\n" "$T" > "$T/cfg/profiles"
hook "" 0
got=$(resolve)
[ "$got" = personal ] ||
  fail "empty+exit0 fell through to the matcher (got '$got', want 'personal')"

# --- non-zero: could not tell, so the matcher DOES run -----------------------
hook "" 1
got=$(resolve)
[ "$got" = matched ] ||
  fail "a failing hook did not fall through (got '$got', want 'matched')"

# ...and with no matcher entry, a failing hook still lands on the default.
rm -f "$T/cfg/profiles"
[ "$(resolve)" = personal ] || fail "failing hook + no rule: want the default"

# A hook that fails but PRINTS must not have its output used: it did not
# answer, so the text is not an answer either.
printf "matched %s\n" "$T" > "$T/cfg/profiles"
hook someprofile 1
got=$(resolve)
[ "$got" != someprofile ] ||
  fail "output of a FAILING hook was used as the answer"
[ "$got" = matched ] || fail "failing hook: want the matcher, got '$got'"
rm -f "$T/cfg/profiles"

# --- an invalid profile is an ERROR, never a silent default ------------------
# The name becomes a directory component (<base>-<profile>) and a pool id, so a
# hook returning a path fragment would choose where valet-key writes. Silently
# resolving it to the default would route a work agent to the personal account.
for bad in '../../etc' 'has space' 'UPPER' 'under_score' '-lead' 'trail-'; do
  hook "$bad" 0
  out=$(resolve_rc) && fail "invalid profile '$bad' was accepted"
  case $out in
    *"invalid profile"*) ;;
    *) fail "invalid profile '$bad' did not say why: '$out'" ;;
  esac
  [ "$out" = personal ] && fail "invalid profile '$bad' became the default"
done

# ...and the legal shapes still pass.
for good in personal manifest client-a x9; do
  hook "$good" 0
  [ "$(resolve)" = "$good" ] || fail "valid profile '$good' was rejected"
done

# --- surrounding whitespace and extra lines are trimmed, not fatal -----------
hook "manifest
second-line" 0
[ "$(resolve)" = manifest ] || fail "hook output not reduced to its first line"

hook "  manifest  " 0
[ "$(resolve)" = manifest ] || fail "surrounding whitespace not trimmed"

# ...but INTERIOR whitespace is rejected, not welded shut. Stripping all space
# would turn an obviously-wrong answer into a legal-looking one.
hook "has space" 0
out=$(resolve_rc) && fail "'has space' was accepted"
case $out in
  *"invalid profile"*) ;;
  *) fail "'has space' was silently mangled rather than rejected: '$out'" ;;
esac

pass
