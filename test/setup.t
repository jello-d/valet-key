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

# check: green on a canonical install
run check >/dev/null 2>&1 || fail "check drifted on a canonical install"

# uninstall: every link removed
run uninstall >/dev/null 2>&1 || fail "uninstall errored"
[ -e "$T/bin/valet-key" ] && fail "bin link not removed"
[ -e "$T/libexec/valet-key" ] && fail "libexec link not removed"
[ -e "$T/share/valet-key" ] && fail "share link not removed"

pass
