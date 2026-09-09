#!/bin/sh
# setup.t - setup.sh install -> assert links -> check -> uninstall -> assert
# gone, against a scratch PREFIX. Nothing outside the sandbox is touched.
. "$(dirname "$0")/lib.sh"
harness_init setup        # sets HERE (repo root) + fail/pass

run() {
  env PREFIX="$T" XDG_BIN_HOME="$T/bin" XDG_DATA_HOME="$T/share" NO_COLOR=1 \
    sh "$HERE/setup.sh" "$@"
}

# install: bin + the namespaced libexec/share + the man page all linked
run install >/dev/null 2>&1 || fail "install errored"
[ "$(readlink "$T/bin/valet-key")" = "$HERE/bin/valet-key" ] || fail "bin link"
[ "$(readlink "$T/libexec/valet-key")" = "$HERE/libexec" ] || fail "libexec"
[ "$(readlink "$T/share/valet-key")" = "$HERE/share" ] || fail "share link"
[ -e "$T/share/man/man1/valet-key.1" ] || fail "man page not linked"

# check: green on a canonical install, and it says so in the marker contract
# an integrator restyles and folds into its own report.
out=$(run check 2>&1) || fail "check drifted on a canonical install"
case $out in *"[OK]"*) ;; *) fail "check emitted no OK markers: $out" ;; esac
case $out in *"[FAIL]"*) fail "a clean install reported a failure: $out" ;; esac

# install is idempotent -- it is what a provisioning layer calls every run.
run install >/dev/null 2>&1 || fail "second install errored"
run check >/dev/null 2>&1 || fail "check drifted after a repeat install"

# ...and drift is caught. Each link is separately load-bearing: without
# libexec the engine finds no adapters and no slot library, and it is a
# symlink to a clone that someone can move out from under it.
for _l in bin/valet-key libexec/valet-key share/valet-key; do
  mv "$T/$_l" "$T/moved-aside"
  rc=0; out=$(run check 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "check passed with $_l missing (rc=$rc)"
  case $out in *"[FAIL]"*) ;; *) fail "$_l drift emitted no FAIL: $out" ;; esac
  mv "$T/moved-aside" "$T/$_l"
done
run check >/dev/null 2>&1 || fail "the drift checks did not restore the tree"

# A link pointing at some OTHER tree is drift too, not just a missing one.
# Two clones on one box is exactly how a stale install goes unnoticed, and
# the wrong tree EXISTS -- so a check that only asks "is there something
# here" would call it clean while the engine runs out of the other clone.
mkdir -p "$T/otherclone/libexec"
ln -sfn "$T/otherclone/libexec" "$T/libexec/valet-key"
rc=0; run check >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "check passed with libexec pointing at another tree"
run install >/dev/null 2>&1 || fail "re-install over a wrong link errored"
run check >/dev/null 2>&1 || fail "re-install did not repair the wrong link"

# version answers whether or not git can describe the tree; a provisioning
# layer records it, so it must never print nothing.
[ -n "$(run version 2>/dev/null)" ] || fail "version printed nothing"

# An unknown subcommand is a loud usage error, not a silent no-op that looks
# like a successful install.
rc=0; err=$(run nosuchverb 2>&1) || rc=$?
[ "$rc" = 2 ] || fail "an unknown setup.sh command exited $rc, want 2"
case $err in *usage*) ;; *) fail "no usage on an unknown command: $err" ;; esac

# uninstall: every link removed
run uninstall >/dev/null 2>&1 || fail "uninstall errored"
[ -e "$T/bin/valet-key" ] && fail "bin link not removed"
[ -e "$T/libexec/valet-key" ] && fail "libexec link not removed"
[ -e "$T/share/valet-key" ] && fail "share link not removed"

# uninstall twice is not an error either -- and it removes only OUR links. A
# file someone else put in the prefix under a name we install is theirs.
run uninstall >/dev/null 2>&1 || fail "second uninstall errored"
printf 'not ours\n' > "$T/bin/valet-key"
run uninstall >/dev/null 2>&1 || fail "uninstall errored over a real file"
[ -f "$T/bin/valet-key" ] || fail "uninstall deleted a file it did not create"

pass
