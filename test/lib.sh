# test/lib.sh - harness for valet-key's shell tests (test/*.t), sourced by each.
#
# Call `harness_init <name>`: sets HERE (the repo root, so a test reaches
# libexec/<lib>), a private scratch dir T (removed on exit), and
# pass/fail. Pure string/FS logic confined to T; nothing outside T is touched.
# POSIX sh; run one with `sh test/<name>.t` or all with test/run.
#
# THE SANDBOX RULE, since this suite drives a tool whose whole job is to touch
# credential directories: a test may write only under $T. Anything driving the
# engine passes `env -i` with HOME, VALET_KEY_CONFIG, VALET_KEY_POOL_ROOT and
# VALET_KEY_SHIMS_DIR all pointed inside $T, so a bug in the code under test
# cannot reach the real ~/.claude, the real pool, or the real PATH. Tests that
# need a specific adapter set copy bin/ and libexec/ into $T and edit the copy,
# because the engine derives libexec/ from its own resolved path.
#
# The suite, by what it covers:
#   lint            every tracked file: sh syntax, 80 columns, exec bits
#   resolve         the profile.d selection + guard.d veto contracts
#   profile-dir     profile -> config dir, and the `dirs` override table
#   launch          the hot path end to end: resolve/guard/lease/exec
#   shims           shim create/remove/rehash, and help vs the dispatch table
#   adapters        the contract every libexec/adapters/* must satisfy
#   audit           `check` (declarative drift) and `doctor` (environment)
#   doctor-hooks    doctor's checks on the hook seams themselves
#   valet-key-slots the credential-slot pool library
#   setup           setup.sh install/check/uninstall against a scratch prefix
harness_init() {   # <name>
  TEST_NAME=$1
  HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT INT TERM
  # SCRUB the inherited valet-key environment. This is not belt-and-braces: a
  # valet-key-launched agent exports the LIVE adapter's file policy
  # (VALET_KEY_STATIC_FILES and friends), so running the suite from inside one
  # handed the code under test the box's policy instead of its own defaults --
  # and the result depended on what launched the test. It masked a real change
  # for exactly as long as it took to notice.
  for _hv in $(env | sed -n 's/^\(VALET_KEY_[A-Z_]*\)=.*/\1/p'); do
    unset "$_hv"
  done
}
pass() { printf 'ok   %s%s\n' "$TEST_NAME" "${1:+ ($1)}"; }
fail() { printf 'FAIL %s: %s\n' "$TEST_NAME" "$1" >&2; exit 1; }
