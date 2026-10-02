#!/bin/sh
# setup.t - setup.sh places a PAYLOAD and links into it, never into source.
#
# The package is DEPARTED: tackup clones it to ~/.cache/tackup/pkgs/valet-key
# and that clone is re-cloned on every provision sweep and wiped on demand. So
# the old model, symlinking ~/.local/{bin,libexec,share,man} straight into the
# checkout, left every link dangling and the command silently gone. The install
# is now a COPY into one payload tree with links only between installed
# locations (shared-notes/_install-placement.md).
#
# HOME IS FAKED FOR EVERY INVOCATION, not only the steps that are about HOME.
# The conversion added `rm -rf` of a payload and two retire sweeps, and those
# paths derive from HOME when PREFIX is left to its default, so HOME is the
# variable that actually bounds the blast radius. A sandbox must not depend on
# the installer being correct, which is the lesson usher paid for twice: an
# intentionally-unguarded build, run inside what looked like a full sandbox,
# reached the real $HOME and deleted a live venv.
. "$(dirname "$0")/harness_lib"
harness_init setup        # sets HERE (repo root) + fail/pass

PAY=$T/share/valet-key
CFG=$T/config/valet-key
mkdir -p "$T/home"

run() {
  env HOME="$T/home" PREFIX="$T" XDG_BIN_HOME="$T/bin" \
    XDG_DATA_HOME="$T/share" XDG_CONFIG_HOME="$T/config" \
    XDG_STATE_HOME="$T/state" NO_COLOR=1 \
    sh "$HERE/setup.sh" "$@"
}

run install >/dev/null 2>&1 || fail "install errored"

# --- the payload is a COPY, and carries everything the command self-locates --
# bin/valet-key resolves its own real path and reads `../libexec` from it, so a
# payload missing libexec resolves into nothing: no adapters, no slot library.
[ -d "$PAY" ] && [ ! -L "$PAY" ] || fail "payload is not a real directory"
for _d in bin libexec share man; do
  [ -d "$PAY/$_d" ] && [ ! -L "$PAY/$_d" ] ||
    fail "payload is missing a real $_d"
done
[ "$(readlink -f "$PAY/bin/valet-key")" = "$PAY/bin/valet-key" ] ||
  fail "the payload's own bin/valet-key is a link, not a copy"

# --- nothing resolves into the SOURCE tree ----------------------------------
# The whole point of the conversion. A link into the checkout is the violation
# the placement rule exists to catch, and it is what a cache wipe breaks.
for _l in "$T/bin/valet-key" "$T/share/man/man1/valet-key.1" "$CFG/share"; do
  _r=$(readlink -f "$_l" 2>/dev/null || true)
  case $_r in
    "$PAY"|"$PAY"/*) ;;
    "$HERE"/*) fail "$_l resolves into the SOURCE tree: $_r" ;;
    *) fail "$_l does not resolve into the payload: $_r" ;;
  esac
done

# --- THE invariant, proven by RUNNING the installed command ------------------
# Link shapes are circumstantial; what matters is that the engine, invoked
# through the installed link, finds its own libexec. A payload that looks right
# and resolves into an empty libexec would satisfy every assertion above.
_out=$(env HOME="$T/home" NO_COLOR=1 VALET_KEY_CONFIG="$T/cfg" \
  VALET_KEY_POOL_ROOT="$T/pool" "$T/bin/valet-key" check 2>&1 || true)
case $_out in
  *"no pools provisioned"*) ;;
  *) fail "the installed command did not self-locate its libexec: $_out" ;;
esac
# ...and it resolved the payload's libexec, not the source's. A doctored
# adapter in the payload must be the one the installed command sees.
printf 'ADAPTER_ENV=CANARY_ENV\nADAPTER_BASE=$HOME/.canary\nADAPTER_SLOTS=0\n' \
  > "$PAY/libexec/adapters/canary"
printf 'adapter_realbin() { echo /bin/true; }\nadapter_preexec() { :; }\n' \
  >> "$PAY/libexec/adapters/canary"
_out=$(env HOME="$T/home" NO_COLOR=1 VALET_KEY_CONFIG="$T/cfg" \
  VALET_KEY_POOL_ROOT="$T/pool" "$T/bin/valet-key" doctor 2>&1 || true)
case $_out in
  *canary*) ;;
  *) fail "the command read adapters from somewhere other than the payload" ;;
esac
rm -f "$PAY/libexec/adapters/canary"

# --- the config root indexes the payload, and only SHIPPED data -------------
# One place answers "what is configured": the user's files plus a door into the
# shipped defaults. Machine-local roots are deliberately NOT linked here: a
# config root is meant to be shareable, so a link to state would dangle on the
# other box or carry this one onto it.
[ "$(readlink "$CFG/share")" = "$PAY" ] ||
  fail "the config root does not index the payload"
for _bad in shims pool state cache; do
  [ -e "$CFG/$_bad" ] && fail "config root links machine-local state: $_bad"
done

# The README names the derivation, not just today's path, because a snapshot of
# an absolute path stops being true the first time a root moves.
grep -q 'XDG_STATE_HOME' "$CFG/README" || fail "README omits the shims root"
grep -q 'VALET_KEY_POOL_ROOT' "$CFG/README" || fail "README omits the pool"
grep -q 'LIVE CREDENTIALS' "$CFG/README" ||
  fail "README does not warn that the pool holds credentials"

# ...and it NEVER clobbers a file a human touched. The failure that matters is
# not a stale README, it is eating something somebody wrote in their config.
printf 'my own notes\n' > "$CFG/README"
run install >/dev/null 2>&1 || fail "install errored over an edited README"
[ "$(cat "$CFG/README")" = "my own notes" ] ||
  fail "install overwrote a README a human had edited"
rm -f "$CFG/README"
run install >/dev/null 2>&1 || fail "install errored restoring the README"
grep -q 'Generated by valet-key' "$CFG/README" ||
  fail "install did not restore its own README once the edit was gone"

# --- check: green on a canonical install, in the marker contract ------------
out=$(run check 2>&1) || fail "check drifted on a canonical install"
case $out in *"[OK]"*) ;; *) fail "check emitted no OK markers: $out" ;; esac
case $out in *"[FAIL]"*) fail "a clean install reported a failure: $out" ;; esac

# install is idempotent: a copying install RE-COPIES on every provision sweep.
run install >/dev/null 2>&1 || fail "second install errored"
run check >/dev/null 2>&1 || fail "check drifted after a repeat install"

# --- drift is caught, per load-bearing piece --------------------------------
for _l in bin/valet-key share/valet-key/libexec config/valet-key/share; do
  mv "$T/$_l" "$T/moved-aside"
  rc=0; out=$(run check 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "check passed with $_l missing (rc=$rc)"
  case $out in *"[FAIL]"*) ;; *) fail "$_l drift emitted no FAIL: $out" ;; esac
  mv "$T/moved-aside" "$T/$_l"
done
run check >/dev/null 2>&1 || fail "the drift checks did not restore the tree"

# A payload that is a SYMLINK is the pre-conversion shape, and the one thing
# check must never call healthy: that is exactly what it looked like before.
mv "$PAY" "$T/realpay"
ln -sfn "$T/realpay" "$PAY"
rc=0; out=$(run check 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "check passed with the payload as a symlink"
case $out in
  *"still a symlink"*) ;;
  *) fail "a symlinked payload was not named as such: $out" ;;
esac
rm -f "$PAY"; mv "$T/realpay" "$PAY"

# --- the retired layout is swept, and reported while it survives ------------
# A stale ~/.local/libexec/<pkg> is the two-copies hazard in a different dress.
mkdir -p "$T/libexec"
ln -sfn "$HERE/libexec" "$T/libexec/valet-key"
rc=0; out=$(run check 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "check passed with the retired root present"
case $out in
  *"retired root"*) ;;
  *) fail "the retired root was not named: $out" ;;
esac
run install >/dev/null 2>&1 || fail "install errored sweeping the retired root"
[ -e "$T/libexec/valet-key" ] || [ -L "$T/libexec/valet-key" ] &&
  fail "install did not sweep the retired root"
run check >/dev/null 2>&1 || fail "check still drifted after the sweep"

# --- the shims migration, with a canary ------------------------------------
# Shims used to default INSIDE what is now the payload, so the atomic swap
# destroyed them on every install. They are generated state, so they move to
# the state root, and the move is CARRIED rather than announced: a standalone
# user who pasted the literal PATH line keeps a working `claude`.
rm -rf "$T/state/valet-key/shims"
mkdir -p "$PAY/shims"
ln -sfn "$PAY/bin/valet-key" "$PAY/shims/canary"
run install >/dev/null 2>&1 || fail "install errored with shims to migrate"
[ -L "$T/state/valet-key/shims/canary" ] ||
  fail "the shims canary did not survive the move into the state root"
[ -d "$PAY/shims" ] && fail "shims were left inside the payload"

# ...and a second install does not disturb the moved dir.
run install >/dev/null 2>&1 || fail "install errored after the migration"
[ -L "$T/state/valet-key/shims/canary" ] ||
  fail "a later install destroyed the migrated shims"

# With shims at BOTH paths the live one is not guessed at, and the payload
# copy is moved OUT of the destruction path rather than "left alone": the swap
# replaces the payload wholesale, so leaving it there would destroy the very
# directory the warning says it preserved. That was the first version's bug.
mkdir -p "$PAY/shims"; : > "$PAY/shims/second"
out=$(run install 2>&1) || fail "install errored with shims at both paths"
case $out in *both*) ;; *) fail "two shims dirs were not reported: $out" ;; esac
[ -e "$T/state/valet-key/shims.superseded/second" ] ||
  fail "the superseded shims dir was destroyed instead of set aside"
[ -L "$T/state/valet-key/shims/canary" ] || fail "the live shims were lost"
[ -d "$PAY/shims" ] && fail "a shims dir was left where the swap destroys it"

# A THIRD install, with the set-aside already taken, declines to guess and
# must still not destroy what it declined to move.
mkdir -p "$PAY/shims"; : > "$PAY/shims/third"
out=$(run install 2>&1) || fail "install errored with the set-aside taken"
case $out in *hand*) ;; *) fail "the unresolvable case was not reported" ;; esac
[ -e "$PAY/shims/third" ] ||
  fail "install destroyed a shims dir it said it had left alone"
rm -rf "$PAY/shims" "$T/state/valet-key/shims.superseded"

# --- the usual CLI contract -------------------------------------------------
[ -n "$(run version 2>/dev/null)" ] || fail "version printed nothing"
run paths | grep -q '^payload	' || fail "paths does not report the payload"
run paths | grep -q '^pool	' || fail "paths does not report the pool"

rc=0; err=$(run nosuchverb 2>&1) || rc=$?
[ "$rc" = 2 ] || fail "an unknown setup.sh command exited $rc, want 2"
case $err in *usage*) ;; *) fail "no usage on an unknown command: $err" ;; esac

# --- uninstall removes what it placed, and nothing else --------------------
run install >/dev/null 2>&1
mkdir -p "$CFG/hooks/guard.d"; printf 'mine\n' > "$CFG/profiles"
mkdir -p "$T/state/valet-key/shims"; : > "$T/state/valet-key/shims/keep"
run uninstall >/dev/null 2>&1 || fail "uninstall errored"
[ -e "$PAY" ] && fail "uninstall left the payload"
[ -e "$T/bin/valet-key" ] && fail "uninstall left the bin link"
[ -e "$CFG/share" ] && fail "uninstall left the config index link"
# The user's own config, the generated shims and the pool are NOT ours to
# remove: config is theirs, shims are state they put on PATH, and the pool
# holds live credentials.
[ "$(cat "$CFG/profiles")" = mine ] || fail "uninstall ate the user's config"
[ -e "$T/state/valet-key/shims/keep" ] || fail "uninstall removed the shims"

# uninstall twice is not an error, and it removes only OUR links: a real file
# someone put at an install point is theirs.
run uninstall >/dev/null 2>&1 || fail "second uninstall errored"
printf 'not ours\n' > "$T/bin/valet-key"
run uninstall >/dev/null 2>&1 || fail "uninstall errored over a real file"
[ -f "$T/bin/valet-key" ] || fail "uninstall deleted a file it did not create"

pass
