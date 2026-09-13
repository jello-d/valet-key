#!/bin/sh
# test/valet-key-slots.t - the credential-slot pool lib (libexec/slots):
# provisioning + seeding, the runtime-lock healing, leasing / dead-
# holder reclaim / overflow, drift, the login warm/check/force flow, and the
# stale scan. Pure string/FS logic in a scratch dir; nothing on the box is
# touched.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init valet-key-slots

SLOTS=$HERE/libexec/slots
ID=claude/personal                       # pool id = <agent>/<profile>
export VALET_KEY_PROC_MATCH=claude           # the adapter's cmdline guard

# --- provisioning + seeding ---------------------------------------------------
D=$T/slots; B=$D/.claude; P=$D/pool/$ID
mkdir -p "$B/projects" "$B/plugins"
printf '{"oauthAccount":{},"hasCompletedOnboarding":true}\n' > "$B/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"A","refreshToken":"R"}}\n' \
  > "$B/.credentials.json"
printf '{"theme":"dark"}\n' > "$B/settings.json"
printf 'hist\n' > "$B/history.jsonl"
echo shared > "$B/projects/marker"
export VALET_KEY_POOL_ROOT="$D/pool"

# a live holder whose argv contains "claude", matching the pid_live guard.
printf '#!/bin/sh\nsleep 30\n' > "$T/claude-hold"; chmod +x "$T/claude-hold"
holder() { "$T/claude-hold" >/dev/null 2>&1 & echo $!; }

sh "$SLOTS" provision "$ID" "$B" 2 >/dev/null || fail "provision failed"
[ -L "$P/slot-1/projects" ] || fail "projects not a dir symlink"
[ "$(cat "$P/slot-1/projects/marker")" = shared ] || fail "dir not shared"
[ -L "$P/slot-1/settings.json" ] || fail "settings.json not a symlink"
[ -f "$P/slot-1/.claude.json" ] && [ ! -L "$P/slot-1/.claude.json" ] \
  || fail ".claude.json not a seeded real file"
[ -e "$P/slot-1/.credentials.json" ] && fail "credentials leaked to slot"
# history.jsonl is SHARED, not private: it is append-only, so concurrent
# writers cannot corrupt it, and leaving it per-slot fragments prompt recall
# into a different past per slot.
[ -L "$P/slot-1/history.jsonl" ] || fail "history.jsonl was not shared"
[ "$(readlink "$P/slot-1/history.jsonl")" = "$B/history.jsonl" ] ||
  fail "history.jsonl points somewhere other than the base"

# pools / counts: the machine-readable enumeration the engine's check + doctor
# drive. Post-provision the two slots are cold and unleased.
[ "$(sh "$SLOTS" pools)" = "$ID" ] || fail "pools did not list the one pool"
[ "$(sh "$SLOTS" counts "$ID")" = "2 0 0" ] || fail "counts post-provision"

# a runtime lock in the base must NEVER be shared into a slot: a shared refresh
# lock defeats the isolation and, once the base lock clears, the slot symlink
# dangles and wedges the next refresh (mkdir -> EEXIST) into a forced re-login.
LK=.oauth_refresh.lock
mkdir "$B/$LK"                                    # base mid-refresh (a lockdir)
sh "$SLOTS" sync "$ID" "$B" >/dev/null 2>&1 || fail "sync w/ base lock failed"
[ -e "$P/slot-1/$LK" ] && fail "runtime lock shared into a slot"
rmdir "$B/$LK"
ln -s "$B/$LK" "$P/slot-1/$LK"                    # stale shared link (dangling)
sh "$SLOTS" sync "$ID" "$B" >/dev/null 2>&1 || fail "sync healing lock failed"
[ -L "$P/slot-1/$LK" ] && fail "stale lock symlink not healed"

# --- ADOPTION: a file that used to be private is folded in, not discarded ----
# When history.jsonl moved from private-per-slot to shared, every existing slot
# already held a real copy with records nothing else had -- 754 prompts on the
# pool this was written for. link_into refuses to clobber a real file, which is
# right, so without adoption the migration would either lose them or leave ten
# drift warnings and the fragmentation intact forever.
AD=$T/adopt; ADB=$T/adoptbase; mkdir -p "$ADB"
printf '{"timestamp":9,"display":"from-base"}\n' > "$ADB/history.jsonl"
printf '{}\n' > "$ADB/.claude.json"
printf '{"theme":"base"}\n' > "$ADB/settings.json"
export VALET_KEY_MERGE_CMD=$HERE/libexec/merge/claude
VALET_KEY_POOL_ROOT=$AD sh "$SLOTS" provision "$ID" "$ADB" 2 >/dev/null
# A slot as it would look BEFORE the change: a real, private copy.
rm -f "$AD/$ID/slot-1/history.jsonl"
printf '{"timestamp":2,"display":"only-in-slot"}\n' \
  > "$AD/$ID/slot-1/history.jsonl"
VALET_KEY_POOL_ROOT=$AD sh "$SLOTS" sync "$ID" "$ADB" >/dev/null 2>&1

[ -L "$AD/$ID/slot-1/history.jsonl" ] ||
  fail "an adopted file was not linked to the shared copy afterwards"
grep -q only-in-slot "$ADB/history.jsonl" ||
  fail "adoption DISCARDED the records only the slot had"
grep -q from-base "$ADB/history.jsonl" ||
  fail "adoption lost what the shared copy already held"
# ...in TIMESTAMP order, so recall reads as one history rather than two
# spliced together. The slot's record is older than the base's, so file order
# and timestamp order disagree -- without sorting, the base's would come first.
[ "$(head -1 "$ADB/history.jsonl" | grep -c only-in-slot)" = 1 ] ||
  fail "the adopted records were not merged in timestamp order"

# Idempotent: syncing again must not duplicate anything.
_n=$(grep -c . "$ADB/history.jsonl")
VALET_KEY_POOL_ROOT=$AD sh "$SLOTS" sync "$ID" "$ADB" >/dev/null 2>&1
[ "$(grep -c . "$ADB/history.jsonl")" = "$_n" ] ||
  fail "a second sync duplicated the adopted records"

# A file that CANNOT be safely unioned is never adopted. settings.json is a
# document, not a log: merging two versions of it means nothing, so a real one
# is left alone and reported as drift, exactly as before.
rm -f "$AD/$ID/slot-2/settings.json"
printf '{"theme":"mine"}\n' > "$AD/$ID/slot-2/settings.json"
VALET_KEY_POOL_ROOT=$AD sh "$SLOTS" sync "$ID" "$ADB" 2>&1 | grep -q drift ||
  fail "a non-adoptable real file was silently adopted instead of reported"
_s2=$AD/$ID/slot-2/settings.json
[ -f "$_s2" ] && [ ! -L "$_s2" ] ||
  fail "a non-adoptable real file was replaced by a link"
unset VALET_KEY_MERGE_CMD

# --- SHARING: concurrent appends from two sessions both survive -------------
# The reason this file can be shared at all. Appends do not conflict, so two
# sessions writing at once cannot lose each other's prompts -- which a
# read-modify-write document could not promise.
SH=$T/shared; SHB=$T/sharedbase; mkdir -p "$SHB"
printf '{}\n' > "$SHB/.claude.json"; : > "$SHB/history.jsonl"
VALET_KEY_POOL_ROOT=$SH sh "$SLOTS" provision "$ID" "$SHB" 2 >/dev/null
_i=0
while [ "$_i" -lt 40 ]; do
  _i=$((_i + 1))
  printf '{"timestamp":%s,"display":"one"}\n' "$_i" \
    >> "$SH/$ID/slot-1/history.jsonl" &
  printf '{"timestamp":%s,"display":"two"}\n' "$_i" \
    >> "$SH/$ID/slot-2/history.jsonl" &
done
wait
[ "$(grep -c . "$SHB/history.jsonl")" = 80 ] ||
  fail "concurrent appends lost entries: $(grep -c . "$SHB/history.jsonl")/80"
_torn=$(python3 -c '
import json, sys
bad = 0
for l in open(sys.argv[1]):
    if not l.strip(): continue
    try: json.loads(l)
    except Exception: bad += 1
print(bad)' "$SHB/history.jsonl")
[ "$_torn" = 0 ] || fail "concurrent appends interleaved: $_torn torn lines"

# --- a <slot>.lock sibling is NOT a slot -------------------------------------
# Found live: the agent creates its own lock directory next to the slot it is
# using, named <slot>.lock. It matches the `slot-*` glob and it IS a directory,
# so the bare `[ -d ]` test these loops used let it through as a slot. A real
# pool of 10 reported 14 -- which threw off warm and leased counts, saturation
# warnings and `check` alike -- and cmd_lease walked the same list, so a lock
# directory could be leased out and handed to an agent AS ITS CONFIG DIR.
mkdir -p "$P/slot-1.lock" "$P/slot-99.lock" "$P/slot-notanumber"
_cnt=$(sh "$SLOTS" counts "$ID")
[ "$_cnt" = "2 0 0" ] ||
  fail "a <slot>.lock sibling was counted as a slot: $_cnt"
sh "$SLOTS" check "$ID" "$B" 2>/dev/null | grep -q '2 slots' ||
  fail "check counted a lock dir as a slot"
# ...and it is never handed out. Every real slot is leased first, so a lease
# that returns a .lock path (or anything but a slot or the base) is the bug.
hl1=$(holder); hl2=$(holder); hl3=$(holder); sleep 0.2
for _h in "$hl1" "$hl2" "$hl3"; do
  _got=$(sh "$SLOTS" lease "$ID" "$B" "$_h" 2>/dev/null)
  case $_got in
    "$P"/slot-[0-9]|"$P"/slot-[0-9][0-9]|"$B") ;;
    *) fail "lease handed out something that is not a slot: $_got" ;;
  esac
done
kill "$hl1" "$hl2" "$hl3" 2>/dev/null || true; wait 2>/dev/null || true
for _s in "$P"/slot-*.lock; do
  [ -e "$_s/.lease" ] && fail "a lock dir was leased: $_s"
done
rm -rf "$P/slot-1.lock" "$P/slot-99.lock" "$P/slot-notanumber" \
       "$P"/slot-*/.lease

# --- leasing / overflow / dead-holder reclaim ---------------------------------
h1=$(holder); h2=$(holder); sleep 0.2
a=$(sh "$SLOTS" lease "$ID" "$B" "$h1")
b=$(sh "$SLOTS" lease "$ID" "$B" "$h2")
[ "$a" != "$b" ] || fail "two leases returned the same slot"
o=$(sh "$SLOTS" lease "$ID" "$B" "$h1" 2>/dev/null)
[ "$o" = "$B" ] || fail "overflow did not fall back to base"
kill "$h2" 2>/dev/null; wait "$h2" 2>/dev/null || true
h3=$(holder); sleep 0.2
r=$(sh "$SLOTS" lease "$ID" "$B" "$h3")
[ "$r" = "$b" ] || fail "dead-holder slot not reclaimed"
kill "$h1" "$h3" 2>/dev/null; wait 2>/dev/null || true

# --- a claim in flight is BUSY, never stolen --------------------------------
# Claiming is mkdir-then-write-pid, so there is an instant where the lock
# exists and the pid file does not. Reading that as "no holder recorded, so it
# must be stale" would let a second leaser tear down a lock the first had just
# taken and hand both of them the same slot -- the token race the pool exists
# to remove. An absent or empty pid means busy, and busy means leave it alone.
MF=$T/midflight; mkdir -p "$MF"
VALET_KEY_POOL_ROOT=$MF sh "$SLOTS" provision "$ID" "$B" 2 >/dev/null
mkdir -p "$MF/$ID/slot-1/.lease"            # lock taken, pid not yet written
hm=$(holder); sleep 0.2
got=$(VALET_KEY_POOL_ROOT=$MF sh "$SLOTS" lease "$ID" "$B" "$hm" 2>/dev/null)
[ "$got" != "$MF/$ID/slot-1" ] ||
  fail "a claim in flight (no pid recorded) was stolen"
[ "$got" = "$MF/$ID/slot-2" ] || fail "the leaser did not move on: ${got##*/}"
kill "$hm" 2>/dev/null || true; wait "$hm" 2>/dev/null || true

# An EMPTY pid file is the same state a moment later, and reads the same way.
: > "$MF/$ID/slot-1/.lease/pid"
rm -rf "$MF/$ID/slot-2/.lease"
hm=$(holder); sleep 0.2
got=$(VALET_KEY_POOL_ROOT=$MF sh "$SLOTS" lease "$ID" "$B" "$hm" 2>/dev/null)
[ "$got" != "$MF/$ID/slot-1" ] || fail "an empty pid file was treated as stale"
kill "$hm" 2>/dev/null || true; wait "$hm" 2>/dev/null || true

# --- which slot wins: WARMTH first, position only as the tiebreak -----------
# A COLD slot at a LOWER index must not beat a WARM one further along. This is
# the case the first version of this test missed, and it cost a real login: a
# session took cold slot-7 while warm slot-9 sat free beside it, because the
# scan was ordered by index alone. The pool exists to keep you logged in, so
# warmth outranks position.
WP=$T/warmpref; mkdir -p "$WP"
VALET_KEY_POOL_ROOT=$WP sh "$SLOTS" provision "$ID" "$B" 3 >/dev/null
printf '{"claudeAiOauth":{"refreshToken":"r"}}\n' \
  > "$WP/$ID/slot-3/.credentials.json"      # only the LAST slot is warm
hw=$(holder); sleep 0.2
got=$(VALET_KEY_POOL_ROOT=$WP sh "$SLOTS" lease "$ID" "$B" "$hw" 2>/dev/null)
[ "$got" = "$WP/$ID/slot-3" ] ||
  fail "lease took a cold low-index slot over a warm one: ${got##*/}"
kill "$hw" 2>/dev/null || true; wait "$hw" 2>/dev/null || true

# ...and the same when the warm slot has to be RECLAIMED rather than being
# free: a dead holder on a warm slot still beats a free cold one.
rm -rf "$WP/$ID"/slot-*/.lease
mkdir -p "$WP/$ID/slot-3/.lease"; echo 999999 > "$WP/$ID/slot-3/.lease/pid"
hw=$(holder); sleep 0.2
got=$(VALET_KEY_POOL_ROOT=$WP sh "$SLOTS" lease "$ID" "$B" "$hw" 2>/dev/null)
[ "$got" = "$WP/$ID/slot-3" ] ||
  fail "a reclaimable WARM slot lost to a free cold one: ${got##*/}"
kill "$hw" 2>/dev/null || true; wait "$hw" 2>/dev/null || true

# With warmth equal, position decides -- so the pool fills predictably rather
# than scattering across slots.
rm -rf "$WP/$ID"/slot-*/.lease "$WP/$ID/slot-3/.credentials.json"
hw=$(holder); sleep 0.2
got=$(VALET_KEY_POOL_ROOT=$WP sh "$SLOTS" lease "$ID" "$B" "$hw" 2>/dev/null)
[ "$got" = "$WP/$ID/slot-1" ] ||
  fail "with all slots cold, index order did not decide: ${got##*/}"
kill "$hw" 2>/dev/null || true; wait "$hw" 2>/dev/null || true

# --- and a reclaimable WARM one still beats a free COLD one -----------------
# The scan takes the first slot that is free OR reclaimable, in order, and
# that ordering is the policy rather than an accident. Skipping ahead to an
# untouched slot instead of recycling an earlier one that already holds a
# login costs the user a sign-in for nothing -- and a pool would drift toward
# every slot being warm, which is the opposite of paying only for the
# concurrency you use.
PR=$T/pref; mkdir -p "$PR"
VALET_KEY_POOL_ROOT=$PR sh "$SLOTS" provision "$ID" "$B" 3 >/dev/null
printf '{"claudeAiOauth":{"refreshToken":"r"}}\n' \
  > "$PR/$ID/slot-1/.credentials.json"          # slot-1 warm...
mkdir -p "$PR/$ID/slot-1/.lease"
echo 999999 > "$PR/$ID/slot-1/.lease/pid"       # ...but its holder is dead
hp1=$(holder); sleep 0.2
got=$(VALET_KEY_POOL_ROOT=$PR sh "$SLOTS" lease "$ID" "$B" "$hp1" 2>/dev/null)
[ "$got" = "$PR/$ID/slot-1" ] ||
  fail "lease skipped a warm reclaimable slot for a cold one: $got"
kill "$hp1" 2>/dev/null || true; wait "$hp1" 2>/dev/null || true

# --- reclaim is GATED on the pool mutex, deterministically ------------------
# The stress test below can only ever catch the race probabilistically: the
# window between removing a dead lock and creating ours is microseconds wide.
# So the PROPERTY the fix rests on is tested directly instead -- recycling
# happens only while holding the pool's reclaim mutex.
#
# Every slot dead-held and none free, with the mutex held by a LIVE process:
# a leaser must NOT recycle anything. It waits, gives up, finds no free slot,
# and overflows to the shared base. If it comes back with a slot, reclaim
# happened outside the mutex and the serialisation is gone.
GM=$T/gated; mkdir -p "$GM"
VALET_KEY_POOL_ROOT=$GM sh "$SLOTS" provision "$ID" "$B" 2 >/dev/null
for _s in "$GM/$ID"/slot-*; do
  mkdir -p "$_s/.lease"; echo 999999 > "$_s/.lease/pid"   # dead holders
done
hg=$(holder)                                  # a LIVE pid to own the mutex
mkdir -p "$GM/$ID/.reclaim"; echo "$hg" > "$GM/$ID/.reclaim/pid"
hg2=$(holder); sleep 0.2
got=$(VALET_KEY_POOL_ROOT=$GM sh "$SLOTS" lease "$ID" "$B" "$hg2" 2>/dev/null)
[ "$got" = "$B" ] ||
  fail "a slot was recycled while the reclaim mutex was held: ${got##*/}"

# ...and a mutex whose owner is GONE must not wedge the pool forever: the next
# leaser breaks it and recycles normally.
kill "$hg" 2>/dev/null || true; wait "$hg" 2>/dev/null || true
echo 999999 > "$GM/$ID/.reclaim/pid"          # owner recorded but dead
got=$(VALET_KEY_POOL_ROOT=$GM sh "$SLOTS" lease "$ID" "$B" "$hg2" 2>/dev/null)
case $got in
  "$GM/$ID"/slot-*) ;;
  *) fail "a stale reclaim mutex wedged the pool: $got" ;;
esac
kill "$hg2" 2>/dev/null || true; wait "$hg2" 2>/dev/null || true

# --- concurrent reclaim: two leasers must never get the same slot ------------
# The state that triggers it is ordinary, not exotic: every slot held by a pid
# that died (a reboot, a killed terminal), and several sessions starting at
# once. Reclaiming used to be `rm -rf` then `mkdir`, which two leasers could
# interleave so that the second DELETED THE FIRST'S LIVE LOCK and both walked
# away holding the same slot -- one credentials file, two live sessions, which
# is the exact token race the pool exists to remove.
#
# Repeated rounds because a race that reproduces sometimes is still a race: on
# the pre-fix code this fired within a dozen rounds.
# Each leaser must present its OWN live holder whose cmdline matches
# $VALET_KEY_PROC_MATCH. Passing a pid that does not match would make every
# lease look reclaimable to everyone -- correct behaviour, but it would hide
# the race this is here to catch behind an expected duplicate.
CP=$T/conc; mkdir -p "$CP" "$T/cout"
VALET_KEY_POOL_ROOT=$CP sh "$SLOTS" provision "$ID" "$B" 3 >/dev/null
_round=0
while [ "$_round" -lt 12 ]; do
  _round=$((_round + 1))
  rm -f "$T/cout"/* "$T/holders"
  for _s in "$CP/$ID"/slot-*; do          # every holder recorded but DEAD
    rm -rf "$_s/.lease" "$_s"/.lease.dead.*
    mkdir -p "$_s/.lease"; echo 999999 > "$_s/.lease/pid"
  done
  _i=0
  while [ "$_i" -lt 5 ]; do               # MORE leasers than slots: contention
    _i=$((_i + 1))
    _h=$(holder); echo "$_h" >> "$T/holders"
    VALET_KEY_POOL_ROOT=$CP sh "$SLOTS" lease "$ID" "$B" "$_h" \
      > "$T/cout/$_i" 2>/dev/null &
  done
  wait
  while read -r _h; do kill "$_h" 2>/dev/null || true; done < "$T/holders"
  _dupe=$(cat "$T/cout"/* | grep 'slot-' | sort | uniq -d)
  [ -z "$_dupe" ] ||
    fail "round $_round: two leasers were handed the same slot: $_dupe"
  # Every slot must be handed out exactly once; the surplus leasers overflow
  # to the shared base. Fewer than 3 means a reclaim was lost.
  _got=$(cat "$T/cout"/* | grep -c 'slot-')
  [ "$_got" = 3 ] || fail "round $_round: $_got of 3 slots were reclaimed"
done
# ...and the reclaim leaves nothing behind that a later run has to reason about.
for _s in "$CP/$ID"/slot-*; do
  for _l in "$_s"/.lease.dead.*; do
    [ -e "$_l" ] && fail "reclaim left a stray lock dir: $_l"
  done
done

rm "$P/slot-2/settings.json"
echo '{}' > "$P/slot-2/settings.json"            # a real file over a link
sh "$SLOTS" sync "$ID" "$B" 2>&1 | grep -q drift \
  || fail "drift (real file over a link) not reported"

no=$(VALET_KEY_POOL_ROOT=$D/nopool sh "$SLOTS" lease "$ID" "$B" $$)
[ "$no" = "$B" ] || fail "missing pool did not fall back to base"

# --- login: warm / check / force ----------------------------------------------
# _run_on_slot execs $VALET_KEY_AGENT_BIN with $VALET_KEY_CRED_ENV=<slot>; the
# stub
# records its target AND writes credentials, so warm/force transitions are real.
STUB=$T/claude-stub
CR='{"claudeAiOauth":{"accessToken":"x","refreshToken":"y"}}'
cat > "$STUB" <<STUBEOF
#!/bin/sh
echo "\$CLAUDE_CONFIG_DIR" > "$T/warmed"
printf '%s\n' '$CR' > "\$CLAUDE_CONFIG_DIR/.credentials.json"
STUBEOF
chmod +x "$STUB"
export VALET_KEY_AGENT_BIN=$STUB VALET_KEY_CRED_ENV=CLAUDE_CONFIG_DIR
AB=$T/adbase; mkdir -p "$AB"; printf '{}\n' > "$AB/.claude.json"
AP=$T/adpool/$ID
LG() { VALET_KEY_POOL_ROOT=$T/adpool sh "$SLOTS" "$@" "$ID" "$AB"; }
VALET_KEY_POOL_ROOT=$T/adpool sh "$SLOTS" provision "$ID" "$AB" 3 >/dev/null

rm -f "$T/warmed"; LG warm >/dev/null 2>&1                 # warm 1st cold slot
[ "$(cat "$T/warmed")" = "$AP/slot-1" ] || fail "warm did not target slot-1"
[ -s "$AP/slot-1/.credentials.json" ] || fail "warm did not warm slot-1"

rm -f "$T/warmed"; LG warm >/dev/null 2>&1                 # warm next cold slot
[ "$(cat "$T/warmed")" != "$AP/slot-1" ] || fail "warm re-warmed slot-1"

out=$(LG login-check 2>&1)
printf '%s' "$out" | grep -q "2/3 warm" || fail "login-check count wrong"
printf '%s' "$out" | grep -q "rotated" || fail "login-check no rotation age"
[ "$(LG counts)" = "3 2 0" ] || fail "counts warm-tally wrong"

touch -d @1000000000 "$AP/slot-1/.credentials.json"       # slot-1 = oldest
rm -f "$T/warmed"; LG force >/dev/null 2>&1
[ "$(cat "$T/warmed")" = "$AP/slot-1" ] || fail "force did not pick the oldest"

LG warm >/dev/null 2>&1; rm -f "$T/warmed"                 # warm last cold slot
out=$(LG warm 2>&1)                                        # pool now full
printf '%s' "$out" | grep -q FULL || fail "full pool not reported"
[ ! -f "$T/warmed" ] || fail "launched on a full pool"

# force on an all-cold pool has nothing to refresh
VALET_KEY_POOL_ROOT=$T/adpool2 sh "$SLOTS" provision "$ID" "$AB" 2 >/dev/null
out=$(VALET_KEY_POOL_ROOT=$T/adpool2 sh "$SLOTS" force "$ID" "$AB" 2>&1)
printf '%s' "$out" | grep -qi "no warm slots" \
  || fail "force on a cold pool not handled"

# --- stale: warm slots within STALE_DAYS of the cap, across all pools ---------
SP=$T/stalepool
mkdir -p "$SP/$ID/slot-1" "$SP/$ID/slot-2" "$SP/$ID/slot-3"
now_ms=$(( $(date +%s) * 1000 ))
creds() {   # <slot> <refreshTokenExpiresAt-ms>
  printf '{"claudeAiOauth":{"refreshToken":"r","refreshTokenExpiresAt":%s}}\n' \
    "$2" > "$1/.credentials.json"
}
creds "$SP/$ID/slot-1" $(( now_ms + 3 * 86400000 ))       # 3d -> within window
creds "$SP/$ID/slot-2" $(( now_ms + 20 * 86400000 ))      # 20d -> outside
# slot-3 stays cold -> never stale
out=$(VALET_KEY_POOL_ROOT=$SP sh "$SLOTS" stale)
printf '%s\n' "$out" | grep -q "^$ID/slot-1 " || fail "near-cap slot not listed"
printf '%s\n' "$out" | grep -q 'slot-2' && fail "far slot wrongly listed"
printf '%s\n' "$out" | grep -q 'slot-3' && fail "cold slot listed"
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] \
  || fail "expected exactly one near-cap line"

# --- login-stale: re-login exactly the slots `stale` would have listed -------
# The write half of the same question. It must pick the same slots -- a
# re-login flow that missed one would leave a session to discover the cap the
# hard way, and one that took them all would burn a login on a fresh slot.
LS() { VALET_KEY_POOL_ROOT=$SP sh "$SLOTS" "$@" "$ID" "$AB"; }
rm -f "$T/warmed"
out=$(LS login-stale 2>&1)
[ "$(cat "$T/warmed" 2>/dev/null)" = "$SP/$ID/slot-1" ] \
  || fail "login-stale did not re-login the near-cap slot"
printf '%s' "$out" | grep -q 'slot-1' || fail "login-stale did not name it"
printf '%s' "$out" | grep -q 'slot-2' && fail "login-stale touched a far slot"

# With nothing near the cap it is a clean no-op that SAYS so, rather than
# printing nothing and leaving the caller unsure it ran.
creds "$SP/$ID/slot-1" $(( now_ms + 30 * 86400000 ))
rm -f "$T/warmed"
out=$(LS login-stale 2>&1)
printf '%s' "$out" | grep -qi "none within" \
  || fail "login-stale was a silent no-op on a fresh pool"
[ -f "$T/warmed" ] && fail "login-stale logged in with nothing near the cap"

# --- provision CONVERGES on N, rather than only ever growing ----------------
# It used to just create 1..N, so asking for 2 over a pool of 5 left 5 -- and
# check called that healthy, because nothing had recorded what was asked for.
# Asserted 2, actual 5, green marker.
CV=$T/conv; CB=$T/convbase; mkdir -p "$CB"; printf '{}\n' > "$CB/.claude.json"
PV() {   # <verb> [trailing args] -- id and base go in the middle
  _v=$1; shift
  VALET_KEY_POOL_ROOT=$CV sh "$SLOTS" "$_v" "$ID" "$CB" "$@"
}
nslots() { ls -d "$CV/$ID"/slot-* 2>/dev/null | grep -c . || true; }

PV provision 5 >/dev/null
[ "$(nslots)" = 5 ] || fail "provision 5 did not make 5 slots"
PV provision 2 >/dev/null
[ "$(nslots)" = 2 ] || fail "provision 2 over 5 left $(nslots) slots, want 2"
VALET_KEY_POOL_ROOT=$CV sh "$SLOTS" check "$ID" "$CB" >/dev/null 2>&1 \
  || fail "check failed on a converged pool"

# Growing again is the same operation in the other direction.
PV provision 4 >/dev/null
[ "$(nslots)" = 4 ] || fail "provision could not grow the pool back"

# A WARM surplus slot is NOT discarded. It holds a login someone sat through a
# browser flow for; throwing that away to satisfy an arithmetic target is not
# a trade this should make on its own. It is kept, said out loud, and the
# resulting gap shows up as drift rather than being quietly normalised.
printf '{"claudeAiOauth":{"refreshToken":"r"}}\n' \
  > "$CV/$ID/slot-4/.credentials.json"
out=$(PV provision 2 2>&1)
[ -s "$CV/$ID/slot-4/.credentials.json" ] ||
  fail "provision discarded a warm slot's login to hit the target"
printf '%s' "$out" | grep -qi 'warm' || fail "the kept warm slot was not named"

# ...and `check` must NOT call that a failure. provision chose this state
# deliberately and said so; reporting it as drift made the tool disagree with
# itself and produced a red line that re-running provisioning could not clear
# -- which is the one thing check promises, since it audits what provisioning
# owns and CAN re-fix. Found on a live box, where a warm, leased slot-10 kept
# `tackup check` permanently red.
rc=0
VALET_KEY_POOL_ROOT=$CV sh "$SLOTS" check "$ID" "$CB" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] ||
  fail "check failed on a surplus slot that provision deliberately kept"
out=$(VALET_KEY_POOL_ROOT=$CV sh "$SLOTS" check "$ID" "$CB" 2>&1)
printf '%s' "$out" | grep -qi 'kept' ||
  fail "check did not explain why the pool is over its requested size"

# A surplus slot that provision WOULD have removed -- cold and unleased -- is
# drift, because its presence means provisioning has not run.
rm -f "$CV/$ID/slot-4/.credentials.json"
rc=0
VALET_KEY_POOL_ROOT=$CV sh "$SLOTS" check "$ID" "$CB" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "a cold, removable surplus slot was not reported as drift"
out=$(VALET_KEY_POOL_ROOT=$CV sh "$SLOTS" check "$ID" "$CB" 2>&1 || true)
printf '%s' "$out" | grep -q 'size drift' || fail "size drift was not named"

# Too FEW slots is always drift: provision creates them, so the gap is real.
rm -rf "$CV/$ID/slot-4" "$CV/$ID/slot-2"
rc=0
VALET_KEY_POOL_ROOT=$CV sh "$SLOTS" check "$ID" "$CB" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "a pool smaller than requested was not reported as drift"
PV provision 4 >/dev/null

# A LEASED surplus slot is never removed either: a live session is using it.
h=$(holder); sleep 0.2
PV provision 4 >/dev/null
VALET_KEY_POOL_ROOT=$CV sh "$SLOTS" lease "$ID" "$CB" "$h" >/dev/null
out=$(PV provision 1 2>&1)
[ -d "$CV/$ID/slot-1" ] || fail "provision removed a leased slot"
kill "$h" 2>/dev/null || true; wait "$h" 2>/dev/null || true

# A pool made before sizes were recorded has no declared value, so there is
# nothing to compare against and nothing to report. Inventing one would
# manufacture drift instead of detecting it.
rm -f "$CV/$ID/.size"
VALET_KEY_POOL_ROOT=$CV sh "$SLOTS" check "$ID" "$CB" >/dev/null 2>&1 \
  || fail "a pool with no recorded size was reported as drifted"

# --- stale is filtered by agent, because the policy is per-agent ------------
# Which file holds the credential, and the pattern that reads a cap out of it,
# come from the adapter. An unfiltered scan can only be right for one agent at
# a time: run it with another agent's policy in the environment and every
# capped slot reports "cap unknown" -- a silent no-op in the one feature whose
# whole job is to speak up before a slot goes cold.
creds "$SP/$ID/slot-1" $(( now_ms + 3 * 86400000 ))    # near cap again
out=$(VALET_KEY_POOL_ROOT=$SP sh "$SLOTS" stale claude)
printf '%s\n' "$out" | grep -q "^$ID/slot-1 " ||
  fail "an agent-filtered stale scan missed its own pool"
mkdir -p "$SP/otheragent/personal/slot-1"
creds "$SP/otheragent/personal/slot-1" $(( now_ms + 1 * 86400000 ))
out=$(VALET_KEY_POOL_ROOT=$SP sh "$SLOTS" stale claude)
printf '%s\n' "$out" | grep -q otheragent &&
  fail "a filtered scan reported another agent's pool"
rm -rf "$SP/otheragent"

# --- the argument contract --------------------------------------------------
# These verbs are reached both from the engine and by hand (`valet-key slots
# ...`), so bad input has to stop rather than improvise a path under $HOME.
rc=0; sh "$SLOTS" provision "$ID" "$AB" notanumber >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "provision accepted a non-numeric slot count (rc=$rc)"
rc=0; sh "$SLOTS" provision "$ID" "$T/no-such-base" 1 >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "provision accepted a missing base dir (rc=$rc)"
rc=0
VALET_KEY_POOL_ROOT=$T/nowhere sh "$SLOTS" check "$ID" "$AB" >/dev/null 2>&1 \
  || rc=$?
[ "$rc" = 1 ] || fail "check on an absent pool did not fail (rc=$rc)"

# An unknown verb exits 2, distinct from the 1 a real failure uses: a typo in
# a caller is not the same event as a pool that is broken.
rc=0; sh "$SLOTS" nosuchverb >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "an unknown slots verb exited $rc, want 2"
rc=0; sh "$SLOTS" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "slots with no verb exited $rc, want 2"

# counts on a pool that is not there answers in the machine-readable shape
# anyway, so a caller parsing it cannot be handed an empty string.
out=$(sh "$SLOTS" counts nosuch/pool 2>/dev/null || true)
[ "$out" = "0 0 0" ] || fail "counts on a missing pool printed '$out'"

pass
