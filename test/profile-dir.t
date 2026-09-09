#!/bin/sh
# profile-dir.t - where a profile's credentials actually land.
#
# resolve.t answers "which profile"; this answers "and therefore which
# directory". It is the second half of the same decision and the one with
# teeth: the directory is what the agent reads its login out of, so a wrong
# answer here does not misconfigure a session, it hands a work agent the
# personal account (or the reverse).
#
# Two rules, in order:
#   1. an explicit <agent> <profile> <dir> line in $VALET_KEY_CONFIG/dirs, for
#      a config dir that must live at a specific path -- a sealed location, or
#      a tool whose env var points at a HOME rather than a config dir;
#   2. otherwise the adapter's base for the DEFAULT profile, <base>-<profile>
#      for any other.
#
# The override table is keyed on BOTH agent and profile, and the properties
# worth pinning are the ones a half-written matcher would get wrong: a line
# for another agent must not leak across, and neither must a line for another
# profile of the same agent.
#
# Drives the real extracted functions. Nothing outside the scratch dir.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init profile-dir

VK=$HERE/bin/valet-key
mkdir -p "$T/cfg"

fns=$(sed -n '/^profile_dir() {/,/^}/p;/^valid_profile() {/,/^}/p' "$VK")
[ -n "$fns" ] || fail "could not extract profile_dir from bin/valet-key"

# <agent> <profile> -> the resolved config dir. HOME is the scratch dir so a ~
# in the table expands somewhere harmless.
dir() {   # <agent> <profile>
  env HOME="$T/home" VALET_KEY_CONFIG="$T/cfg" sh -c "
      set -eu
      DEFAULT_PROFILE=personal
      AGENT=$1
      ADAPTER_BASE=\$HOME/.$1
      $fns
      profile_dir $2"
}
H=$T/home

# --- no table: the adapter's naming rule ------------------------------------
# The default profile is the agent's NATIVE directory, deliberately: a box
# with one account keeps using ~/.claude, and installing valet-key moves
# nothing.
[ "$(dir claude personal)" = "$H/.claude" ] ||
  fail "default profile did not map to the base: $(dir claude personal)"
[ "$(dir claude work)" = "$H/.claude-work" ] ||
  fail "non-default profile did not map to <base>-<profile>"
[ "$(dir codex client-a)" = "$H/.codex-client-a" ] ||
  fail "the naming rule is not agent-generic"

# --- the override table -----------------------------------------------------
cat > "$T/cfg/dirs" <<EOF
# a comment line, and a blank one, are both skipped

claude  work     ~/sealed/claude-work
gemini  work     /var/tmp/gemini-work
codex   personal ~
EOF

[ "$(dir claude work)" = "$H/sealed/claude-work" ] ||
  fail "an override did not win over the naming rule: $(dir claude work)"
[ "$(dir gemini work)" = /var/tmp/gemini-work ] ||
  fail "an absolute override was not used verbatim"
[ "$(dir codex personal)" = "$H" ] ||
  fail "a bare ~ did not expand to \$HOME: $(dir codex personal)"

# The keying, both halves. A line for ANOTHER AGENT must not leak across --
# claude and gemini both have a `work` profile above, and they are different
# accounts in different places.
[ "$(dir codex work)" = "$H/.codex-work" ] ||
  fail "an override for another agent leaked: $(dir codex work)"
# ...and a line for another PROFILE of the same agent must not either.
[ "$(dir claude personal)" = "$H/.claude" ] ||
  fail "an override for another profile leaked: $(dir claude personal)"

# A commented-out line stays commented out. (The keying alone would reject it
# too; this pins the documented behaviour rather than the accident, so a table
# parser rewritten to be more forgiving cannot start honouring it.)
printf '#claude personal /wrong\n' > "$T/cfg/dirs"
[ "$(dir claude personal)" = "$H/.claude" ] || fail "a commented line was read"

# First matching line wins, so an operator can shadow a later one.
printf 'claude work /first\nclaude work /second\n' > "$T/cfg/dirs"
[ "$(dir claude work)" = /first ] || fail "a later duplicate line won"

# An unreadable/absent table is the normal case, not an error.
rm -f "$T/cfg/dirs"
[ "$(dir claude work)" = "$H/.claude-work" ] ||
  fail "removing the table did not restore the naming rule"

# --- the profile name is a PATH COMPONENT, so it is validated ---------------
# Everything above turns the profile into a directory suffix; that is why
# valid_profile exists. resolve.t covers the character classes on the hook
# path -- here, the LENGTH bound, which is the one a DNS-label check is easy
# to write without.
vp() {   # <name> -> 0 valid, 1 not
  _r=0
  env sh -c "set -eu; $fns; valid_profile \"\$1\"" _ "$1" || _r=$?
  echo "$_r"
}
[ "$(vp personal)" = 0 ] || fail "a plain name was rejected"
[ "$(vp client-a)" = 0 ] || fail "an internal hyphen was rejected"
[ "$(vp a)" = 0 ]        || fail "a one-character name was rejected"
[ "$(vp "$(printf 'a%.0s' $(seq 63))")" = 0 ] ||
  fail "a 63-character name was rejected (the label limit is inclusive)"
[ "$(vp "$(printf 'a%.0s' $(seq 64))")" = 1 ] ||
  fail "a 64-character name was accepted"
[ "$(vp '')" = 1 ] || fail "an empty name was accepted"

pass
