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
[ -e "$P/slot-1/history.jsonl" ] && fail "private file linked into slot"

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

pass
