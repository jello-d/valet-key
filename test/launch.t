#!/bin/sh
# launch.t - the hot path, end to end: resolve -> guard -> config dir -> lease
# -> exec.
#
# Every other test drives one piece in isolation. This one runs the actual
# engine the way a person does, and asserts on what the REAL AGENT sees, which
# is the only thing that finally matters: the four steps can each be correct
# and still hand the process the wrong environment.
#
# The agent is a stub that prints its config dir, whether the API-key override
# was scrubbed, and its arguments -- so "did the launch work" becomes a string
# comparison instead of a login.
#
# Both entry points are exercised, because they are different code paths to
# the same place: the SHIM (a symlink whose $0 basename names the agent, the
# busybox multi-call trick) and `valet-key run <agent>`. A regression that
# breaks only the shim would be invisible to a suite that tested only `run`,
# and the shim is the one people actually type.
#
# Everything is confined to a scratch dir with a scratch $HOME. No pool, no
# config, and no binary outside it is touched.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init launch

VK=$HERE/bin/valet-key
H=$T/home
mkdir -p "$H/.claude" "$T/cfg/hooks/profile.d" "$T/cfg/hooks/guard.d" \
         "$T/shims" "$T/bin"
PD=$T/cfg/hooks/profile.d
GD=$T/cfg/hooks/guard.d

# The stub agent. It reports the three things the engine is responsible for
# handing it: the config dir, the state of the credential-override env var,
# and its argv.
cat > "$T/bin/claude" <<'STUB'
#!/bin/sh
echo "cfg=$CLAUDE_CONFIG_DIR key=${ANTHROPIC_API_KEY-SCRUBBED} args=$*"
STUB
chmod +x "$T/bin/claude"

# A run of the engine, with the box's own environment kept well away: no
# inherited HOME, no inherited PATH, no inherited agent config.
E() {   # <env assignment>... -- <command>...
  env -i PATH=/usr/bin:/bin HOME="$H" NO_COLOR=1 \
    VALET_KEY_CONFIG="$T/cfg" VALET_KEY_POOL_ROOT="$T/pool" \
    VALET_KEY_SHIMS_DIR="$T/shims" CLAUDE_BIN="$T/bin/claude" "$@"
}
mkhook() { printf '%s\n' "$2" > "$1"; chmod +x "$1"; }

# --- the plain case: no pool, no hooks --------------------------------------
# With nothing configured the engine still has to do its job: default profile,
# the agent's own native directory, and the real binary exec'd with our args.
out=$(E sh "$VK" run claude --model sonnet 2>/dev/null)
[ "$out" = "cfg=$H/.claude key=SCRUBBED args=--model sonnet" ] ||
  fail "bare launch handed the agent the wrong environment: $out"

# The announce line goes to STDERR, not stdout: the agent owns stdout, and a
# tool that prints to it corrupts anything piping the agent.
err=$(E sh "$VK" run claude 2>&1 >/dev/null)
case $err in
  *"valet-key: claude profile=personal config=$H/.claude"*) ;;
  *) fail "the launch announcement was not on stderr: $err" ;;
esac

# --- the credential-override scrub ------------------------------------------
# $ANTHROPIC_API_KEY silently outranks the stored OAuth login, so a slot's
# whole point evaporates while it is set. The adapter DECLARES it; the engine
# scrubs it. Without this the agent would run on the key and the profile
# routing would be decorative.
out=$(E ANTHROPIC_API_KEY=leaked sh "$VK" run claude 2>/dev/null)
case $out in
  *"key=SCRUBBED"*) ;;
  *) fail "the declared credential override was not scrubbed: $out" ;;
esac

# --- a pool: the launch lands on a private slot -----------------------------
E sh "$VK" provision claude personal 2 >/dev/null || fail "provision failed"
out=$(E sh "$VK" run claude 2>/dev/null)
case $out in
  "cfg=$T/pool/claude/personal/slot-1 "*) ;;
  *) fail "a provisioned pool did not lease a slot: $out" ;;
esac

# --- the shim: $0 names the agent -------------------------------------------
# The shim is the entry point people type. It must reach the same place, and
# it must NOT recurse into itself: adapter_realbin skips anything resolving to
# the engine, so the shim first on PATH still finds the real binary past it.
E sh "$VK" shim claude >/dev/null 2>&1 || fail "shim creation failed"
out=$(env -i PATH="$T/shims:/usr/bin:/bin" HOME="$H" NO_COLOR=1 \
  VALET_KEY_CONFIG="$T/cfg" VALET_KEY_POOL_ROOT="$T/pool" \
  VALET_KEY_SHIMS_DIR="$T/shims" CLAUDE_BIN="$T/bin/claude" \
  claude viashim 2>/dev/null)
case $out in
  "cfg=$T/pool/claude/personal/slot-1 key=SCRUBBED args=viashim") ;;
  *) fail "the shim entry point diverged from 'run': $out" ;;
esac

# --- selection changes the destination --------------------------------------
# The end-to-end proof that resolve_profile's answer reaches the agent: the
# same command, the same cwd, a different profile, a different config dir.
mkhook "$PD/50-sel" '#!/bin/sh
echo work'
out=$(E sh "$VK" run claude 2>/dev/null)
[ "$out" = "cfg=$H/.claude-work key=SCRUBBED args=" ] ||
  fail "the selected profile did not reach the agent: $out"

# ...and the config dir is CREATED. Some agents (codex) canonicalise the path
# and error on a missing one, so a first launch into a new profile must not
# depend on the directory already existing.
[ -d "$H/.claude-work" ] || fail "the profile's config dir was not created"
rm -f "$PD/50-sel"

# --- the veto actually stops the launch -------------------------------------
# resolve.t proves guard_check computes a refusal. This proves the refusal
# reaches exit(2) before exec, which is the part that protects anything.
mkhook "$GD/50-no" '#!/bin/sh
echo "guard: not here" >&2
exit 1'
rc=0; out=$(E sh "$VK" run claude 2>/dev/null) || rc=$?
[ "$rc" = 1 ] || fail "a refused launch did not exit 1 (got $rc)"
[ -z "$out" ] || fail "a refused launch reached the agent anyway: $out"

# The guard owns the message: its stderr passes through untouched, so the
# person sees the reason rather than a generic refusal.
err=$(E sh "$VK" run claude 2>&1 >/dev/null || true)
case $err in
  *"guard: not here"*) ;;
  *) fail "the guard's own message was swallowed: $err" ;;
esac

# A warn (exit 2) proceeds. It is a different verdict, not a softer refusal.
mkhook "$GD/50-no" '#!/bin/sh
echo "guard: heads up" >&2
exit 2'
out=$(E sh "$VK" run claude 2>/dev/null) || fail "a warning guard blocked exec"
case $out in *"cfg="*) ;; *) fail "a warning guard lost the launch" ;; esac

# The guard is told what it is judging: the profile as $1 and in the
# environment, and the agent too. A guard that only sees "something launched"
# cannot make a per-profile decision, which is most of what guards do.
mkhook "$GD/50-no" '#!/bin/sh
[ "$1" = personal ]                  || { echo "bad arg: $1" >&2; exit 1; }
[ "$VALET_KEY_PROFILE" = personal ]  || { echo "no env profile" >&2; exit 1; }
[ "$VALET_KEY_AGENT" = claude ]      || { echo "no env agent" >&2; exit 1; }
exit 0'
E sh "$VK" run claude >/dev/null 2>&1 ||
  fail "the guard did not receive the profile and agent"
rm -f "$GD"/*

# --- resolve: the same decision, WITHOUT launching --------------------------
# The dry run. Before it existed, the only way to learn which account a
# directory would use was to launch the agent and read its stderr -- run the
# thing you were trying to check first -- and when the answer surprised you
# there was nothing to inspect.
mkhook "$PD/50-sel" '#!/bin/sh
echo work'
out=$(E sh "$VK" resolve claude) || fail "resolve exited non-zero with no guard"
case $out in
  *"profile  work"*) ;;
  *) fail "resolve reported the wrong profile: $out" ;;
esac
case $out in
  *"config   $H/.claude-work"*) ;;
  *) fail "resolve did not report the config dir: $out" ;;
esac
# It must agree with what a launch actually does. Two answers to "which
# account" is the one thing this command cannot have.
run=$(E sh "$VK" run claude 2>/dev/null)
case $run in
  "cfg=$H/.claude-work "*) ;;
  *) fail "resolve and the launch path disagree: $run" ;;
esac
# The chain is shown, not just the winner: which hook answered, and which were
# never asked because it did.
case $out in
  *"profile.d/50-sel -> work"*) ;;
  *) fail "resolve did not show which hook answered: $out" ;;
esac
mkhook "$PD/90-later" '#!/bin/sh
echo never'
case $(E sh "$VK" resolve claude) in
  *"90-later"*"not consulted"*) ;;
  *) fail "resolve did not show the hooks that were skipped" ;;
esac
rm -f "$PD"/*

# It launches NOTHING. A dry run that runs the agent is not a dry run.
rm -f "$T/ran"
cat > "$T/bin/claude" <<STUB
#!/bin/sh
touch "$T/ran"
STUB
chmod +x "$T/bin/claude"
E sh "$VK" resolve claude >/dev/null 2>&1 || true
[ -e "$T/ran" ] && fail "resolve launched the agent"
cat > "$T/bin/claude" <<'STUB'
#!/bin/sh
echo "cfg=$CLAUDE_CONFIG_DIR key=${ANTHROPIC_API_KEY-SCRUBBED} args=$*"
STUB
chmod +x "$T/bin/claude"

# A guard that would refuse makes resolve exit 1, so `valet-key resolve && ...`
# means what it looks like it means.
mkhook "$GD/50-no" '#!/bin/sh
exit 1'
rc=0; out=$(E sh "$VK" resolve claude) || rc=$?
[ "$rc" = 1 ] || fail "resolve did not exit 1 where a launch would be refused"
case $out in
  *"REFUSES"*|*"REFUSED"*) ;;
  *) fail "resolve did not say the launch would be refused: $out" ;;
esac
rm -f "$GD"/*

# --- one rule for "which profile", across every command ---------------------
# These used to disagree: login resolved from context while provision and
# check fell back to the default. So `cd ~/work && valet-key provision claude`
# built the PERSONAL pool while `valet-key login` a line later acted on WORK,
# and nothing said so -- the pool you thought you had made was elsewhere.
mkhook "$PD/50-sel" '#!/bin/sh
echo work'
mkdir -p "$H/.claude-work"
out=$(E sh "$VK" provision claude 2>&1) || fail "provision failed"
case $out in
  *"claude/work"*) ;;
  *) fail "provision did not resolve the profile from context: $out" ;;
esac
# ...and it SAYS which pool it chose, because a resolution you cannot see is a
# resolution you cannot check.
case $out in
  *"valet-key: provisioning claude/work"*) ;;
  *) fail "provision did not announce the pool it picked: $out" ;;
esac
out=$(E sh "$VK" check claude 2>&1) || fail "check failed"
case $out in
  *"claude/work"*) ;;
  *) fail "check did not resolve the profile from context: $out" ;;
esac
out=$(E sh "$VK" login check claude 2>&1) || fail "login check failed"
case $out in *"claude/work"*) ;; *) fail "login disagreed with the rest" ;; esac
# An explicitly named profile still wins over the resolved one.
out=$(E sh "$VK" check claude personal 2>&1) || fail "explicit check failed"
case $out in
  *"claude/personal"*) ;;
  *) fail "an explicit profile was overridden by resolution: $out" ;;
esac
# ...and an unusable explicit name is refused rather than turned into a path.
rc=0; E sh "$VK" check claude ../../escaped >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "an invalid profile argument was accepted (rc=$rc)"
rm -f "$PD"/*

# --- an unknown agent is a loud failure -------------------------------------
rc=0; E sh "$VK" run nosuchagent >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "an unknown agent did not fail (rc=$rc)"

# --- a quiet adapter stays quiet, unless asked ------------------------------
# gcloud is scripted: callers parse its stderr, so an extra line from us is a
# bug in THEIR program. It declares ADAPTER_QUIET, and VALET_KEY_VERBOSE is
# the way back to the announcement when debugging.
mkdir -p "$H/.config/gcloud"
printf '#!/bin/sh\necho "gcloud cfg=$CLOUDSDK_CONFIG"\n' > "$T/bin/gcloud"
chmod +x "$T/bin/gcloud"
err=$(E GCLOUD_BIN="$T/bin/gcloud" sh "$VK" run gcloud 2>&1 >/dev/null)
case $err in
  *"valet-key:"*) fail "a quiet adapter still announced itself: $err" ;;
esac
err=$(E GCLOUD_BIN="$T/bin/gcloud" VALET_KEY_VERBOSE=1 \
  sh "$VK" run gcloud 2>&1 >/dev/null)
case $err in
  *"valet-key: gcloud profile=personal"*) ;;
  *) fail "VALET_KEY_VERBOSE did not restore the announcement: $err" ;;
esac

# A poolless adapter is pointed straight at the profile's dir, never a slot --
# it has no rotating token to isolate, and a pool would only add a layer.
out=$(E GCLOUD_BIN="$T/bin/gcloud" sh "$VK" run gcloud 2>/dev/null)
[ "$out" = "gcloud cfg=$H/.config/gcloud" ] ||
  fail "a poolless agent was not pointed at its profile dir: $out"

pass
