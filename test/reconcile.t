#!/bin/sh
# reconcile.t - sharing agent-written state across a pool, safely.
#
# THE PROBLEM. A slot's .claude.json is a private copy, not a symlink, because
# the agent rewrites it constantly and N sessions on one inode would interleave
# read-modify-write. Correct -- but `projects[<path>]` is where trust,
# per-project allowed tools and MCP approvals live, so the same repo had to be
# trusted again on every slot it had not been opened in, and a new slot started
# knowing nothing.
#
# THE ANSWER is not to share the inode but to RECONCILE the copies: every
# writer keeps its own file, and the copies are converged afterwards. The worst
# case is a merge that loses a cycle and is redone on the next one, never a
# corrupted config.
#
# What this pins, in rough order of how much it would hurt to get wrong:
#   - a REVOCATION is never resurrected. Union is the intuitive merge and the
#     wrong one: trust and allowedTools live INSIDE a project entry, so
#     unioning would restore what you just removed, from a stale sibling.
#   - identity and per-directory state never move. oauthAccount is the account;
#     counters and caches are meaningless merged.
#   - the partition is one pool, base included, and it is never crossed.
#   - a torn source is skipped, not fatal -- sources are live files.
#   - an agent that declares nothing gets none of this.
#
# Nothing outside the scratch dir is touched.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init reconcile

VK=$HERE/bin/valet-key
H=$T/home
mkdir -p "$H/.claude" "$T/bin"
P=$T/pool/claude/personal
printf '#!/bin/sh\n:\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"

E() {
  env -i PATH=/usr/bin:/bin HOME="$H" NO_COLOR=1 \
    VALET_KEY_CONFIG="$T/cfg" VALET_KEY_POOL_ROOT="$T/pool" \
    CLAUDE_BIN="$T/bin/claude" "$@"
}

# Read/write one project entry, so the test states intent rather than JSON.
setp() {   # <file> <project> <trust:yes|no> <tools-json>
  python3 -c '
import json, sys
f, key, trust, tools = sys.argv[1:5]
j = json.load(open(f))
j.setdefault("projects", {})[key] = {
    "hasTrustDialogAccepted": trust == "yes",
    "allowedTools": json.loads(tools),
}
json.dump(j, open(f, "w"))' "$@"
}
getp() {   # <file> <project> <field> -- prints the value, or MISSING
  python3 -c '
import json, sys
try:
    e = json.load(open(sys.argv[1]))["projects"][sys.argv[2]]
except Exception:
    print("MISSING"); raise SystemExit
print(json.dumps(e[sys.argv[3]]))' "$@"
}
top() {    # <file> <key>
  python3 -c '
import json, sys
print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2])))' "$@"
}

printf '{"oauthAccount":{"id":"personal"},"numStartups":7,"projects":{}}\n' \
  > "$H/.claude/.claude.json"
E sh "$VK" provision claude personal 3 >/dev/null || fail "provision failed"

# --- a project learned on ONE member reaches all of them --------------------
setp "$P/slot-2/.claude.json" /repo yes '["Bash"]'
E sh "$VK" reconcile claude personal >/dev/null || fail "reconcile failed"
for m in "$P/slot-1" "$P/slot-2" "$P/slot-3" "$H/.claude"; do
  [ "$(getp "$m/.claude.json" /repo hasTrustDialogAccepted)" = true ] ||
    fail "${m##*/} did not learn the project"
done

# The BASE is in the partition on purpose: it is the overflow target AND what
# provision seeds a new slot from, so reconciling into it is what makes the
# NEXT slot start current instead of blind. That is the durable half of the
# fix; without it every new slot re-learns everything.
E sh "$VK" provision claude personal 4 >/dev/null || fail "grow failed"
[ "$(getp "$P/slot-4/.claude.json" /repo hasTrustDialogAccepted)" = true ] ||
  fail "a newly provisioned slot did not inherit the pool's state"

# --- THE safety property: a revocation is not resurrected -------------------
# Union would restore trust=true and the removed tool from the stale copies.
# Entries are taken whole from the newest writer instead, so removing
# something removes it everywhere.
sleep 1.1                                  # mtime is the clock; be decisive
setp "$P/slot-3/.claude.json" /repo no '[]'
E sh "$VK" reconcile claude personal >/dev/null || fail "reconcile failed"
for m in "$P/slot-1" "$P/slot-2" "$P/slot-3" "$P/slot-4" "$H/.claude"; do
  [ "$(getp "$m/.claude.json" /repo hasTrustDialogAccepted)" = false ] ||
    fail "${m##*/}: a revoked trust was resurrected by the merge"
  [ "$(getp "$m/.claude.json" /repo allowedTools)" = "[]" ] ||
    fail "${m##*/}: a removed tool came back"
done

# --- identity and per-directory state stay put ------------------------------
# oauthAccount IS the account. Even within one pool it is not something to
# copy around, and across pools it would be a leak. Counters are per-copy and
# a merge of them means nothing.
# Every member gets a DISTINCT marker, so this cannot pass by luck of which
# source happened to be read last.
_i=0
for m in "$H/.claude" "$P/slot-1" "$P/slot-2" "$P/slot-3" "$P/slot-4"; do
  _i=$((_i + 1))
  python3 -c '
import json, sys
f, n = sys.argv[1], int(sys.argv[2])
j = json.load(open(f)); j["numStartups"] = n
j["oauthAccount"] = {"id": "identity-%d" % n}
json.dump(j, open(f, "w"))' "$m/.claude.json" "$_i"
done
E sh "$VK" reconcile claude personal >/dev/null || fail "reconcile failed"
_i=0
for m in "$H/.claude" "$P/slot-1" "$P/slot-2" "$P/slot-3" "$P/slot-4"; do
  _i=$((_i + 1))
  [ "$(top "$m/.claude.json" numStartups)" = "$_i" ] ||
    fail "${m##*/}: a per-directory counter was merged between copies"
  [ "$(top "$m/.claude.json" oauthAccount)" = "{\"id\": \"identity-$_i\"}" ] ||
    fail "${m##*/}: the account identity moved between copies"
done

# --- the partition is ONE POOL, and is not crossed --------------------------
mkdir -p "$H/.claude-work"
printf '{"oauthAccount":{"id":"work"},"projects":{}}\n' \
  > "$H/.claude-work/.claude.json"
E sh "$VK" provision claude work 2 >/dev/null || fail "work provision failed"
setp "$H/.claude-work/.claude.json" /secret/work-repo yes '["Bash"]'
E sh "$VK" reconcile claude work >/dev/null || fail "work reconcile failed"
E sh "$VK" reconcile claude personal >/dev/null || fail "reconcile failed"
[ "$(getp "$P/slot-1/.claude.json" /secret/work-repo hasTrustDialogAccepted)" \
  = MISSING ] || fail "a work project leaked into the personal pool"
[ "$(top "$T/pool/claude/work/slot-1/.claude.json" oauthAccount)" \
  = '{"id": "work"}' ] || fail "the work pool's identity was overwritten"

# --- a torn source is skipped, not fatal ------------------------------------
# Sources are live files; one can be caught half-flushed. Failing the whole
# run over that would make this fragile exactly when the pool is busy.
cp "$P/slot-2/.claude.json" "$T/slot2.bak"
setp "$P/slot-4/.claude.json" /survivor yes '[]'     # a GOOD source, mid-run
printf '{"projects": {"/x": ' > "$P/slot-2/.claude.json"     # truncated
E sh "$VK" reconcile claude personal >/dev/null ||
  fail "one unparseable source aborted the reconcile"
# The run must have CONTINUED past the bad file, not merely not-crashed:
# a healthy source's new project still has to land everywhere else.
[ "$(getp "$P/slot-1/.claude.json" /survivor hasTrustDialogAccepted)" = true ] \
  || fail "a torn source stopped a healthy one from propagating"
[ "$(getp "$P/slot-1/.claude.json" /repo hasTrustDialogAccepted)" = false ] ||
  fail "a torn source damaged a healthy copy"
cp "$T/slot2.bak" "$P/slot-2/.claude.json"

# A destination that does not exist is skipped, never invented: creating one
# would have to fabricate the identity and onboarding state this never touches.
rm -f "$P/slot-3/.claude.json"
E sh "$VK" reconcile claude personal >/dev/null || fail "reconcile failed"
[ -e "$P/slot-3/.claude.json" ] &&
  fail "reconcile created a config file out of nothing"
E sh "$VK" provision claude personal 4 >/dev/null   # restore it by seeding

# ...and the helper refuses on its own account, not only because the shell
# skipped it. Both guards matter: the shell one avoids spawning a process,
# this one is what makes the helper safe to call directly.
"$HERE/libexec/merge/claude" .claude.json "$T/nope/.claude.json" \
  "$P/slot-1/.claude.json" >/dev/null 2>&1 ||
  fail "the merge helper errored on an absent destination"
[ -e "$T/nope/.claude.json" ] && fail "the merge helper invented a destination"

# --- --check reports rather than writes -------------------------------------
setp "$P/slot-2/.claude.json" /fresh yes '[]'
rc=0; out=$(E sh "$VK" reconcile claude personal --check 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "--check did not report a pool that is behind (rc=$rc)"
case $out in *behind*) ;; *) fail "--check said nothing useful: $out" ;; esac
[ "$(getp "$P/slot-1/.claude.json" /fresh hasTrustDialogAccepted)" = MISSING ] \
  || fail "--check wrote to a copy it was only supposed to inspect"
E sh "$VK" reconcile claude personal >/dev/null
rc=0; out=$(E sh "$VK" reconcile claude personal --check 2>&1) || rc=$?
[ "$rc" = 0 ] || fail "--check still reported drift after reconciling (rc=$rc)"

# --- the launch path pulls into the slot it is about to use -----------------
# The half that makes this invisible: the slot is current at the instant the
# agent starts, so the trust prompt never appears in the first place.
setp "$P/slot-3/.claude.json" /late yes '[]'
E sh "$VK" run claude >/dev/null 2>&1 || fail "launch failed"
_leased=$(E sh "$VK" run claude 2>&1 >/dev/null | sed 's/.*config=//')
[ "$(getp "$_leased/.claude.json" /late hasTrustDialogAccepted)" = true ] ||
  fail "the leased slot was not brought up to date before exec"

# The stamps are valet-key's bookkeeping and live in the POOL dir. An agent's
# config directory belongs to the agent; dropping our own files in it invites
# the agent to trip over them.
[ -d "$P/.reconciled" ] || fail "no reconcile stamps were recorded"
for _s in "$P"/slot-*/.reconciled*; do
  [ -e "$_s" ] && fail "a stamp was written inside an agent config dir: $_s"
done

# --- doctor surfaces a pool that has not converged --------------------------
# Not a breakage -- nothing is broken and a launch reconciles the slot it
# uses anyway -- but the SYMPTOM (being asked to trust a repo you already
# trusted) reads as the tool misbehaving, so it is worth naming.
setp "$P/slot-2/.claude.json" /drifted yes '[]'
out=$(E sh "$VK" doctor 2>&1 || true)
case $out in
  *"has not converged"*) ;;
  *) fail "doctor did not surface an unconverged pool" ;;
esac
case $out in
  *"valet-key reconcile claude personal"*) ;;
  *) fail "doctor offered no fix for the drift" ;;
esac
# It is an advisory, so it must carry the WARN marker, not FAIL: doctor's red
# lines are reserved for things that are actually broken.
case $(E sh "$VK" doctor 2>&1 || true) in
  *"[WARN]"*"has not converged"*) ;;
  *) fail "unconverged state was not reported as a warning" ;;
esac
E sh "$VK" reconcile claude personal >/dev/null
case $(E sh "$VK" doctor 2>&1 || true) in
  *"has not converged"*) fail "doctor still reported drift after reconciling" ;;
esac

# --- an agent that declares no shared files gets none of this ---------------
# gcloud is poolless and declares nothing, so the whole mechanism must be a
# clean no-op rather than an error.
# A POOLLESS agent has one config dir per profile: no copies, so nothing can
# diverge. It must say so rather than report a missing pool, which would read
# as drift when it is the design working.
mkdir -p "$H/.config/gcloud"
rc=0; out=$(E sh "$VK" reconcile gcloud personal 2>&1) || rc=$?
[ "$rc" = 0 ] || fail "reconcile on a poolless agent failed (rc=$rc)"
case $out in
  *poolless*) ;;
  *) fail "a poolless agent was not explained: $out" ;;
esac
case $out in
  *"no pool"*) fail "poolless was reported as a missing pool: $out" ;;
esac

# A POOLED agent that simply declares no merge files is also a clean no-op --
# that is how an agent opts out, and it must not look like a failure.
mkdir -p "$H/.codex"
E sh "$VK" provision codex personal 2 >/dev/null ||
  fail "codex provision failed"
rc=0; out=$(E sh "$VK" reconcile codex personal 2>&1) || rc=$?
[ "$rc" = 0 ] || fail "reconcile on an agent with no merge files failed"
case $out in
  *"no shared files"*) ;;
  *) fail "an agent with no merge files was not explained: $out" ;;
esac

pass
