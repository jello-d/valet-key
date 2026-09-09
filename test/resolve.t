#!/bin/sh
# resolve.t - the two hook seams: profile.d SELECTS, guard.d VETOES.
#
# valet-key must decide two things it cannot always know: which profile applies
# here, and whether it may launch at all. They are irreducibly different -- a
# veto is not a profile name, a selection cannot say "stop" -- so they are two
# seams, and a hook's DIRECTORY says which question it answers. No verb
# argument, no dispatch, and no need to answer a question you do not care about.
#
# The properties that matter, and why:
#   selection: first hook that ANSWERS wins; a non-zero exit means "I cannot
#              tell" and is the ONLY thing that passes to the next hook. Empty
#              output with exit 0 is a real answer ("definitely the default"),
#              so a provider that knows the baseline can say so instead of
#              inventing a token -- and a BROKEN hook cannot be mistaken for
#              one that deliberately said "baseline".
#   veto:      EVERY hook runs and ANY refusal refuses. Adding a guard must
#              only ever make things stricter, or a second guard could silently
#              cancel the first.
#
# Drives the real extracted functions. Nothing outside the scratch dir.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init resolve

VK=$HERE/bin/valet-key
mkdir -p "$T/cfg/hooks/profile.d" "$T/cfg/hooks/guard.d"
PD=$T/cfg/hooks/profile.d
GD=$T/cfg/hooks/guard.d

fns=$(sed -n '/^valid_profile() {/,/^}/p;
              /^here_dir() {/,/^}/p;/^resolve_profile() {/,/^}/p;
              /^guard_check() {/,/^}/p' "$VK")
[ -n "$fns" ] || fail "could not extract the seams from bin/valet-key"

drive() {   # <expr>
  ( cd "$T" && env VALET_KEY_CONFIG="$T/cfg" sh -c "
      set -eu
      DEFAULT_PROFILE=personal
      VALET_KEY_CONFIG=\$VALET_KEY_CONFIG
      VALET_KEY_HOOKS=\$VALET_KEY_CONFIG/hooks
      $fns
      $1" )
}
resolve()    { drive resolve_profile 2>/dev/null; }
resolve_rc() { drive resolve_profile 2>&1; }
guard_rc()   { _r=0; drive "guard_check personal" >/dev/null 2>&1 || _r=$?
               echo "$_r"; }
mkhook() { printf '%s\n' "$2" > "$1"; chmod +x "$1"; }

# --- no hooks: the built-in rule, then the default -------------------------
[ "$(resolve)" = personal ] || fail "no hooks: want the default profile"
[ "$(guard_rc)" = 0 ]       || fail "no guards: want proceed"

# --- selection: a hook that answers wins -----------------------------------
mkhook "$PD/50-a" '#!/bin/sh
echo manifest'
[ "$(resolve)" = manifest ] || fail "a profile hook's answer was ignored"

# --- selection: ORDER decides, not luck ------------------------------------
# Two providers may legitimately disagree, so the operator orders them.
mkhook "$PD/10-first" '#!/bin/sh
echo winner'
[ "$(resolve)" = winner ] || fail "name order did not decide: got $(resolve)"

# --- selection: non-zero = "cannot tell" and passes to the NEXT hook -------
mkhook "$PD/10-first" '#!/bin/sh
echo ignored-because-it-failed
exit 1'
[ "$(resolve)" = manifest ] ||
  fail "an abstaining hook did not pass to the next: got $(resolve)"

# --- selection: exit 0 + EMPTY is an ANSWER, and stops the chain -----------
# It means "definitely the default here". If it fell through, a provider could
# not say that, and the cwd table would start guessing behind its back.
printf 'matched %s\n' "$T" > "$T/cfg/profiles"
mkhook "$PD/10-first" '#!/bin/sh
exit 0'
got=$(resolve)
[ "$got" = personal ] ||
  fail "empty+exit0 did not stop the chain (got '$got', want personal)"
rm -f "$PD/10-first"

# ...whereas when every hook abstains, the cwd table DOES run.
mkhook "$PD/50-a" '#!/bin/sh
exit 1'
[ "$(resolve)" = matched ] ||
  fail "all-abstain did not fall through to the cwd rule: $(resolve)"
rm -f "$T/cfg/profiles" "$PD"/*

# --- the cwd table: a REPO resolves the same way from anywhere inside it ----
# The context is the git root, not $PWD. That is the difference between a
# rule that works and one that surprises: a session started in a repo's
# deeply-nested subdirectory is the same piece of work as one started at its
# top, and must reach the same account.
if command -v git >/dev/null 2>&1; then
  mkdir -p "$T/tree/repo/src/deep"
  ( cd "$T/tree/repo" && git init -q . ) || fail "could not make a test repo"
  printf 'byroot %s/tree\n' "$T" > "$T/cfg/profiles"
  deep() {   # resolve with the cwd set to <dir>
    ( cd "$1" && env VALET_KEY_CONFIG="$T/cfg" sh -c "
        set -eu
        DEFAULT_PROFILE=personal
        VALET_KEY_CONFIG=\$VALET_KEY_CONFIG
        VALET_KEY_HOOKS=\$VALET_KEY_CONFIG/hooks
        $fns
        resolve_profile" ) 2>/dev/null
  }
  [ "$(deep "$T/tree/repo")" = byroot ] || fail "a repo root did not match"
  [ "$(deep "$T/tree/repo/src/deep")" = byroot ] ||
    fail "a subdirectory of a matched repo resolved differently from its root"

  # A sibling path sharing a prefix is NOT inside the tree: the comparison is
  # on path components, not on strings.
  mkdir -p "$T/tree-other/repo"
  ( cd "$T/tree-other/repo" && git init -q . ) || fail "second repo failed"
  got=$(deep "$T/tree-other/repo")
  [ "$got" = personal ] ||
    fail "a sibling path sharing a prefix was matched: $got"

  # The case that proves it is the GIT ROOT and not merely $PWD. A rule
  # pointing INSIDE a repo does not match, because the repo is one piece of
  # work with one account -- resolving it by cwd would give the same session
  # two different logins depending on which subdirectory it started in.
  printf 'byroot %s/tree/repo/src\n' "$T" > "$T/cfg/profiles"
  got=$(deep "$T/tree/repo/src/deep")
  [ "$got" = personal ] ||
    fail "a rule pointing inside a repo matched by cwd (got '$got')"

  # ...and outside a repo there is no root, so $PWD is the context and the
  # same rule does match. Without that fallback the table would only work in
  # repositories.
  mkdir -p "$T/plain/src/deep"
  printf 'bycwd %s/plain/src\n' "$T" > "$T/cfg/profiles"
  got=$(deep "$T/plain/src/deep")
  [ "$got" = bycwd ] ||
    fail "outside a repo the cwd was not the context (got '$got')"
  rm -f "$T/cfg/profiles"
fi

# --- a hook path containing a SPACE is still a hook -------------------------
# This used to be a silent loss. The hook list was captured and word-split, so
# "10 my hook" became three nonexistent paths, each of which "failed" -- and a
# failure is a legitimate answer on both seams. Selection read it as "I cannot
# tell" and moved on; a guard would have been read as a refusal it never made.
# Either way the hook was gone and nothing said so. A space in $HOME is
# ordinary on some systems, so the path here is not exotic.
mkhook "$PD/50-spaced name" '#!/bin/sh
echo spaced'
[ "$(resolve)" = spaced ] ||
  fail "a hook whose path holds a space was skipped: $(resolve)"
rm -f "$PD"/*

mkhook "$GD/50-spaced name" '#!/bin/sh
exit 1'
[ "$(guard_rc)" = 1 ] ||
  fail "a guard whose path holds a space did not refuse"
rm -f "$GD"/*

# --- the cwd table is validated too, not just hook output -------------------
# The name becomes a directory component and half a pool id whichever input it
# arrived on. Validating only the hook would leave the guard looking present
# while the other door stood open -- and a table is hand-edited, which makes a
# stray `../` at least as likely there.
# (A name with a space is not testable here and does not need to be: the table
# is whitespace-delimited, so such a name cannot be written in it.)
for bad in '../../escaped' 'UPPER' 'under_score' '-lead'; do
  printf '%s %s\n' "$bad" "$T" > "$T/cfg/profiles"
  out=$(resolve_rc) && fail "profiles table accepted '$bad'"
  case $out in
    *"invalid profile"*) ;;
    *) fail "an invalid table profile did not say why: '$out'" ;;
  esac
done
rm -f "$T/cfg/profiles"

# --- selection: an unusable name is an ERROR, never a silent default -------
# The name becomes a directory component, so a hook returning a path fragment
# would choose where valet-key writes.
for bad in '../../etc' 'has space' 'UPPER' 'under_score' '-lead' 'trail-'; do
  mkhook "$PD/50-a" "#!/bin/sh
echo '$bad'"
  out=$(resolve_rc) && fail "invalid profile '$bad' was accepted"
  case $out in
    *"invalid profile"*) ;;
    *) fail "invalid profile '$bad' did not say why: '$out'" ;;
  esac
  [ "$out" = personal ] && fail "invalid profile '$bad' became the default"
done
rm -f "$PD"/*

# --- veto: any refusal refuses ----------------------------------------------
mkhook "$GD/50-ok" '#!/bin/sh
exit 0'
[ "$(guard_rc)" = 0 ] || fail "an allowing guard blocked the launch"

mkhook "$GD/10-no" '#!/bin/sh
exit 1'
[ "$(guard_rc)" = 1 ] || fail "a refusing guard did not refuse"

# ...and order does not matter for a veto: strictest wins wherever it sits.
rm -f "$GD"/*
mkhook "$GD/10-ok" '#!/bin/sh
exit 0'
mkhook "$GD/90-no" '#!/bin/sh
exit 1'
[ "$(guard_rc)" = 1 ] || fail "a LATER refusal was cancelled by an earlier ok"

# --- veto: a guard that cannot RUN counts as a refusal ---------------------
# A safety check that failed has not cleared anything; failing open would be
# the one direction this must never fail in.
rm -f "$GD"/*
mkhook "$GD/50-broken" '#!/bin/sh
exec definitely-not-a-real-command'
[ "$(guard_rc)" = 1 ] || fail "a broken guard failed OPEN"

# --- veto: warn proceeds, and a warn cannot mask a refusal -----------------
rm -f "$GD"/*
mkhook "$GD/50-warn" '#!/bin/sh
exit 2'
[ "$(guard_rc)" = 0 ] || fail "a warning guard blocked the launch"
mkhook "$GD/60-no" '#!/bin/sh
exit 1'
[ "$(guard_rc)" = 1 ] || fail "a warn masked a refusal"

# --- the seams are INDEPENDENT ---------------------------------------------
# A veto-only integrator writes one file in guard.d and says nothing about
# profiles; that must not affect selection at all.
rm -f "$PD"/* "$GD"/*
mkhook "$GD/50-vetoonly" '#!/bin/sh
exit 0'
[ "$(resolve)" = personal ] || fail "a guard hook influenced selection"

pass
