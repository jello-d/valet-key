# test/lib.sh - harness for valet-key's shell tests (test/*.t), sourced by each.
#
# Call `harness_init <name>`: sets HERE (the repo root, so a test reaches
# libexec/<lib>), a private scratch dir T (removed on exit), and
# pass/fail. Pure string/FS logic confined to T; nothing outside T is touched.
# POSIX sh; run one with `sh test/<name>.t` or all with test/run.
harness_init() {   # <name>
  TEST_NAME=$1
  HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT INT TERM
}
pass() { printf 'ok   %s%s\n' "$TEST_NAME" "${1:+ ($1)}"; }
fail() { printf 'FAIL %s: %s\n' "$TEST_NAME" "$1" >&2; exit 1; }
