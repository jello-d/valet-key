#!/bin/sh
# audit.t - the two diagnostics, and the line between them.
#
# `check` audits the PROVISIONED state: pools present, slots counted, no
# structural drift. It is the declarative half -- everything it reports,
# provisioning owns and can re-fix.
#
# `doctor` audits the LIVE ENVIRONMENT, which provisioning cannot touch: does
# typing the agent actually route through valet-key, is an API key in the
# shell shadowing every slot login, is a pool saturated, is a slot near its
# cap. Read-only, and it deliberately fails on only ONE class of thing -- a
# breakage -- so that a wall of advisories never trains anyone to ignore a red
# line.
#
# Both are worth testing precisely because nobody reads their output closely.
# A diagnostic that silently stops noticing is worse than no diagnostic: it
# actively certifies a broken setup.
#
# The engine is driven from a COPY of the package in the scratch dir, so the
# adapter set is ours: the engine derives libexec/ from its own resolved path,
# which means a copied tree lets us add and remove agents at will. That is the
# only way to assert on "an agent that is not installed" without depending on
# what this particular box happens to have in /usr/bin.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init audit

H=$T/home
mkdir -p "$H" "$T/pkg" "$T/front" "$T/cfg" "$T/tree"
cp -R "$HERE/bin" "$HERE/libexec" "$T/pkg/"
VK=$T/pkg/bin/valet-key
AD=$T/pkg/libexec/adapters

# Our adapter set: claude (the real pooled one) plus two synthetic agents that
# exist to put doctor's shim verdicts under our control. The other bundled
# adapters are removed rather than worked around, because whether this box has
# a real gemini or gcloud on PATH is not something a test may depend on.
rm -f "$AD/codex" "$AD/gemini" "$AD/gcloud"
synth() {   # <name>
  cat > "$AD/$1" <<EOF
ADAPTER_ENV=$(echo "$1" | tr 'a-z-' 'A-Z_')_CONFIG
ADAPTER_BASE=\$HOME/.$1
ADAPTER_SLOTS=0
adapter_realbin() { command -v $1 2>/dev/null || return 1; }
adapter_preexec() { :; }
EOF
}
synth unshimmed      # a real binary of this name will sit unshimmed on PATH
synth absent         # nothing of this name exists anywhere

# A SECOND pooled agent, sorting after claude, whose credential file and cap
# policy are different -- and whose cap pattern is empty, meaning "this agent
# records no absolute cap" (codex is the real example). Its presence is the
# whole point: a cross-pool scan carries per-agent policy in the environment,
# so it can only ever be right for one agent at a time, and getting that wrong
# turns the cap warning into a silent no-op for everybody else.
cat > "$AD/zpooled" <<'EOF'
ADAPTER_ENV=ZPOOLED_HOME
ADAPTER_BASE=$HOME/.zpooled
ADAPTER_SLOTS=1
ADAPTER_CRED_FILE=auth.json
ADAPTER_PROC_MATCH=zpooled
ADAPTER_EXP_PATTERN=
adapter_realbin() { command -v zpooled 2>/dev/null || return 1; }
adapter_preexec() { :; }
EOF

E() {   # run the engine with the box's own environment kept out
  env -i PATH="$T/front:/usr/bin:/bin" HOME="$H" NO_COLOR=1 \
    VALET_KEY_CONFIG="$T/cfg" VALET_KEY_POOL_ROOT="$T/pool" \
    VALET_KEY_SHIMS_DIR="$T/front" "$@"
}
has() {   # <output> <substring> <message>
  case $1 in *"$2"*) ;; *) fail "$3: $1" ;; esac
}
hasnt() { case $1 in *"$2"*) fail "$3: $1" ;; esac; }

# ===========================================================================
# check -- the declarative drift audit
# ===========================================================================

# No pools at all is a legitimate state, not a finding: valet-key without a
# pool still resolves profiles, and a poolless agent never has one. It must
# read as IGNORE and exit 0, or a fresh install looks broken.
rc=0; out=$(E sh "$VK" check) || rc=$?
[ "$rc" = 0 ] || fail "check on a fresh box exited $rc"
has "$out" "[IGNORE]" "no pools should be IGNORE, not a finding"
has "$out" "no pools provisioned" "check did not say why it found nothing"

mkdir -p "$H/.claude"
E sh "$VK" provision claude personal 2 >/dev/null || fail "provision failed"

# A healthy pool: OK, with the counts, and a zero status.
rc=0; out=$(E sh "$VK" check) || rc=$?
[ "$rc" = 0 ] || fail "check on a healthy pool exited $rc"
has "$out" "[OK]" "a healthy pool was not OK"
has "$out" "claude/personal" "the pool was not named"
has "$out" "2 slots" "the slot count was not reported"

# Naming the pool explicitly audits just that one.
out=$(E sh "$VK" check claude personal) || fail "single-pool check failed"
has "$out" "claude/personal" "single-pool check did not name the pool"

# A pool that should exist and does not is the headline failure, and it must
# reach the EXIT STATUS -- an integrator folds that into its own report and
# never reads the text.
rc=0; out=$(E sh "$VK" check claude work) || rc=$?
[ "$rc" = 1 ] || fail "check on a missing pool exited $rc, want 1"
has "$out" "[FAIL]" "a missing pool was not marked FAIL"
has "$out" "MISSING" "a missing pool did not say what was wrong"

# Structural drift inside a present pool: a shared link whose target is gone.
# The pool still LOOKS provisioned -- right slot count, right names -- which
# is exactly why this has to be checked rather than eyeballed.
ln -s "$H/.claude/vanished" "$T/pool/claude/personal/slot-1/dangler"
rc=0; out=$(E sh "$VK" check claude personal) || rc=$?
[ "$rc" = 1 ] || fail "a dangling shared link did not fail check (rc=$rc)"
has "$out" "[FAIL]" "a dangling link was not marked FAIL"
rm -f "$T/pool/claude/personal/slot-1/dangler"

# A pool on disk for an agent valet-key no longer knows. It cannot be audited
# and it cannot be repaired, so it is a FAILURE and not a shrug: something
# provisioned it, and whatever that was has gone away.
mkdir -p "$T/pool/ghostagent/personal/slot-1"
rc=0; out=$(E sh "$VK" check) || rc=$?
[ "$rc" = 1 ] || fail "an orphan pool did not fail check (rc=$rc)"
has "$out" "no adapter for 'ghostagent'" "the orphan pool was not explained"
# ...and it does not stop the sweep: the healthy pool is still reported.
has "$out" "claude/personal" "one bad pool aborted the whole sweep"
rm -rf "$T/pool/ghostagent"

# ===========================================================================
# doctor -- the environmental sweep
# ===========================================================================
# doctor's TEXT, with its status discarded (asserted separately, below): a
# non-zero exit is one of the things under test here, and it must not abort
# the test that is examining the output that explains it.
doc() { E "$@" sh "$VK" doctor 2>&1 || true; }
doc_rc() { _r=0; E "$@" sh "$VK" doctor >/dev/null 2>&1 || _r=$?; echo "$_r"; }

# The shim verdicts, all three, on agents we control. This is doctor's whole
# reason to exist: a shim that does not win on PATH means every launch has
# been bypassing valet-key entirely, silently, for as long as it has been
# wrong.
E sh "$VK" shim claude >/dev/null 2>&1 || fail "shim creation failed"
printf '#!/bin/sh\n:\n' > "$T/front/unshimmed"; chmod +x "$T/front/unshimmed"

out=$(doc)
has "$out" "claude routes through valet-key" "a working shim was not confirmed"
has "$out" "unshimmed resolves to" "a bypassed agent was not flagged"
has "$out" "not the shim" "the bypass was not explained"
has "$out" "absent: not on PATH" "an uninstalled agent was not IGNOREd"
# An uninstalled agent is not a problem -- most boxes run one or two of these.
hasnt "$out" "[FAIL] absent" "an uninstalled agent was treated as a breakage"

[ "$(doc_rc)" = 1 ] || fail "a shim that does not intercept did not fail doctor"

# Only the binary goes: the adapter stays, because the next check needs an
# agent that loads AFTER claude, and it now reads as simply not installed.
rm -f "$T/front/unshimmed"
[ "$(doc_rc)" = 0 ] || fail "removing the bypassed binary did not clear doctor"

# A leaked API key outranks every slot login, so the pool silently stops
# mattering. It is a WARNING, not a failure: it may well be deliberate.
out=$(doc ANTHROPIC_API_KEY=leaked)
has "$out" "[WARN]" "a leaked API key was not warned about"
has "$out" 'claude: $ANTHROPIC_API_KEY is set' "the leak named the wrong var"
[ "$(doc_rc ANTHROPIC_API_KEY=leaked)" = 0 ] ||
  fail "an advisory changed doctor's exit status"

# Adapter state must not bleed between agents in one sweep. doctor loads every
# adapter in turn, and a knob one agent sets legitimately (claude's
# ANTHROPIC_API_KEY) must not be inherited by the next one that omits it --
# which would report a leak against an agent that has nothing to do with the
# variable, from a single real one. Adapters load in name order, and
# `unshimmed` sorts after `claude` and declares no override of its own, so a
# missing reset shows up as a second warning.
_n=$(doc ANTHROPIC_API_KEY=leaked | grep -c 'ANTHROPIC_API_KEY is set')
[ "$_n" = 1 ] ||
  fail "one leaked key produced $_n warnings; adapter state bled across agents"

out=$(doc)
has "$out" "no agent API key leaking" "a clean environment was not confirmed"

# A saturated pool: every slot leased, so the NEXT launch overflows to the
# shared base and quietly reintroduces the token race the pool exists to
# prevent. Nothing is broken yet, which is why it needs saying out loud.
mkdir -p "$H/.claude-saturated"
E sh "$VK" provision claude saturated 1 >/dev/null || fail "provision failed"
printf '#!/bin/sh\nsleep 30\n' > "$T/claude-hold"; chmod +x "$T/claude-hold"
"$T/claude-hold" >/dev/null 2>&1 & hold=$!
sleep 0.2
E sh "$VK" slots lease claude/saturated "$H/.claude-saturated" "$hold" \
  >/dev/null
out=$(doc)
has "$out" "saturated" "a fully-leased pool was not flagged"
has "$out" "1/1 leased" "the saturation was not quantified"
has "$out" "valet-key provision claude saturated" "no fix was suggested"
kill "$hold" 2>/dev/null || true; wait "$hold" 2>/dev/null || true
rm -rf "$T/pool/claude/saturated" "$H/.claude-saturated"

# A profile you can REACH with no pool behind it. This is the tool's central
# promise quietly unmet: with no pool, a launch silently uses the shared base
# dir, so every session for that profile shares one credentials file exactly
# as it would if valet-key were not installed. `check` cannot catch it -- it
# audits pools that exist, and this failure's whole shape is a pool that does
# not.
mkdir -p "$H/.claude-unpooled"
printf 'unpooled %s/tree\n' "$T" > "$T/cfg/profiles"
out=$(doc)
has "$out" "claude/unpooled has no pool" "an unpooled profile was not flagged"
has "$out" "$H/.claude-unpooled" "the warning did not name the shared dir"
has "$out" "valet-key provision claude unpooled" "no fix was offered"

# It is a WARNING, not a breakage: you may simply not have set that profile up
# yet, and doctor's red lines have to stay meaningful.
[ "$(doc_rc)" = 0 ] || fail "an unpooled profile changed doctor's exit status"

# A profile named in the table whose account dir does NOT exist is an ordinary
# half-finished setup, not a fault. Warning per agent per never-used profile
# would bury the real ones.
printf 'ghostprofile %s/tree\n' "$T" > "$T/cfg/profiles"
case $(doc) in
  *"ghostprofile has no pool"*)
    fail "warned about a profile whose account dir does not exist" ;;
esac
rm -f "$T/cfg/profiles"; rm -rf "$H/.claude-unpooled"

# A slot near its hard cap. The cap is absolute from login and refreshing does
# NOT extend it, so the only remedy is a re-login BEFORE it lands -- after it
# lands, a session is already being forced to sign in mid-work.
soon=$(( ($(date +%s) + 2 * 86400) * 1000 ))
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":%s}}\n' "$soon" \
  > "$T/pool/claude/personal/slot-1/.credentials.json"
out=$(doc)
has "$out" "near cap" "a slot near its cap was not surfaced"
has "$out" "valet-key login stale" "no re-login was suggested"

# ...and it is still surfaced with a SECOND pooled agent installed whose cap
# policy differs. The scan reads a per-agent credential file with a per-agent
# pattern, so a single pass carrying one agent's policy reports "cap unknown"
# for every other agent. Exactly one line, too: a scan run once per agent
# without filtering would report the same slot as many times as there are
# agents, and a warning that duplicates is a warning people stop reading.
mkdir -p "$H/.zpooled"
E sh "$VK" provision zpooled personal 1 >/dev/null 2>&1 ||
  fail "could not provision the second pooled agent"
out=$(doc)
has "$out" "near cap" "a second pooled agent hid the near-cap slot"
_n=$(printf '%s\n' "$out" | grep -c 'near cap')
[ "$_n" = 1 ] || fail "the near-cap slot was reported $_n times, want 1"
rm -rf "$T/pool/zpooled" "$H/.zpooled"

# The counters are the summary line an integrator greps; they have to add up.
out=$(doc ANTHROPIC_API_KEY=leaked)
has "$out" "valet-key doctor: 2 warning(s), 0 problem(s)" \
  "the summary did not tally the findings"

# ===========================================================================
# the read-only login reports
# ===========================================================================
# `login check` and `stale` are the other two things that only ever LOOK. The
# engine's job in both is resolution: turn an agent and a profile into the
# right pool and the right base before handing off to the slot library. The
# library's own behaviour has its own test; what is checked here is that the
# engine points it at the pool the user meant.

out=$(E sh "$VK" login check claude personal 2>&1) ||
  fail "login check failed on a real pool"
has "$out" "claude/personal" "login check did not resolve the pool"
has "$out" "/2 warm" "login check did not report the pool's warm count"
has "$out" "slot-1" "login check did not list the slots"

# With no profile named it resolves one the same way a launch does, so
# `valet-key login check` in a work tree reports the work pool. Here that is
# the default, which is the answer a box with no rules should get.
out=$(E sh "$VK" login check claude 2>&1) ||
  fail "login check without a profile failed"
has "$out" "claude/personal" "login check did not resolve a default profile"

# With no agent named either, it means claude. That is a real default people
# rely on (`valet-key login` is the whole command most of the time), so it is
# pinned rather than left to be discovered.
out=$(E sh "$VK" login check 2>&1) || fail "login check with no args failed"
has "$out" "claude/personal" "login with no agent did not default to claude"

# `stale` is the whole-box scan an attention banner runs on a timer: one line
# per near-cap slot, nothing else, and silence when there is nothing to say.
out=$(E sh "$VK" stale)
case $out in
  "claude/personal/slot-1 "*d) ;;
  *) fail "stale did not emit '<id>/<slot> <days>d': $out" ;;
esac
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] ||
  fail "stale emitted more than the one near-cap slot: $out"

rm -f "$T/pool/claude/personal/slot-1/.credentials.json"
[ -z "$(E sh "$VK" stale)" ] || fail "stale spoke up with nothing near a cap"

# The WRITE verb, for the one thing the engine contributes to it: `warm` runs
# the real agent binary against a specific slot so a person can sign in. The
# slot library's own choice of slot is tested with the library; what is
# checked here is that the engine resolved a binary at all and handed it the
# slot rather than the base.
cat > "$T/signin" <<'STUB'
#!/bin/sh
echo "$CLAUDE_CONFIG_DIR" > "$SIGNIN_LOG"
printf '{"claudeAiOauth":{"refreshToken":"r"}}\n' \
  > "$CLAUDE_CONFIG_DIR/.credentials.json"
STUB
chmod +x "$T/signin"
E CLAUDE_BIN="$T/signin" SIGNIN_LOG="$T/signed" \
  sh "$VK" login warm claude personal >/dev/null 2>&1 ||
  fail "login warm failed"
case $(cat "$T/signed") in
  "$T/pool/claude/personal/slot-"*) ;;
  *) fail "login warm signed in against $(cat "$T/signed"), not a slot" ;;
esac

# ...and when the agent is not installed at all, login stops before touching
# the pool and says which agent it could not find. Going ahead would leave a
# slot recorded as visited with no login in it.
rc=0; err=$(E sh "$VK" login warm absent personal 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "login for an uninstalled agent exited $rc, want 1"
case $err in
  *"absent"*"not found"*) ;;
  *) fail "login did not name the missing binary: $err" ;;
esac

pass
