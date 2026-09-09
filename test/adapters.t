#!/bin/sh
# adapters.t - the contract every bundled adapter has to satisfy.
#
# An adapter is a shell fragment the engine SOURCES. That is a lot of trust
# for a file with no interface enforced anywhere: a typo in a variable name
# does not error, it produces an empty value, and an empty value here is not
# an obvious failure. It is a quiet one.
#
#   ADAPTER_ENV empty      -> the engine exports "=<dir>", the agent never
#                             hears about the profile, and every launch runs
#                             on the default account.
#   ADAPTER_CRED_FILE      -> the slot pool has no isolation TARGET, so every
#     empty on a pooled       slot counts as warm, seed_slot shares the real
#     agent                   credentials file into every slot, and the token
#                             race the pool exists to prevent comes straight
#                             back with a pool wrapped around it.
#   ADAPTER_PROC_MATCH     -> pid_live matches any process at all, so a lease
#     empty                   is reclaimed from a LIVE session whose pid was
#                             reused.
#
# None of those announce themselves. So the contract is asserted here, over
# every adapter present, rather than documented and hoped for.
#
# The other half is adapter_realbin, which has one safety property that is not
# negotiable: it must never return the valet-key shim. The shim IS the engine,
# so exec'ing it re-enters the engine, which resolves the binary again, and
# the process forks itself until something gives out.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init adapters

AD=$HERE/libexec/adapters
ENGINE=$(readlink -f "$HERE/bin/valet-key")
H=$T/home
mkdir -p "$H/.npm-global/bin" "$T/front" "$T/real"

# The shim: a symlink to the engine, exactly as `valet-key shim` makes one.
shim_at() { ln -sfn "$ENGINE" "$1"; }

# Source <adapter> in a sandbox and run <expr>; the engine's contract is that
# VALET_KEY_SELF is exported before an adapter is consulted.
drive() {   # <adapter> <expr> [env assignment]...
  _a=$1; _e=$2; shift 2
  env -i PATH="$T/front:/usr/bin:/bin" HOME="$H" \
    VALET_KEY_SELF="$ENGINE" "$@" sh -c '
      set -u
      . "$1" || exit 91        # the shared helpers, as the engine sources them
      . "$2" || exit 90
      shift 2
      eval "$@"' _ "$HERE/libexec/adapter.sh" "$AD/$_a" "$_e"
}

# Adapters whose install lands under ~/.npm-global/bin (their own first
# preference). Listed rather than inferred: which paths an adapter prefers is
# a fact about that adapter.
NPM_AGENTS='claude codex gemini'

_n=0
for _p in "$AD"/*; do
  [ -f "$_p" ] || continue
  a=${_p##*/}; _n=$((_n + 1))
  BINVAR=$(echo "$a" | tr 'a-z-' 'A-Z_')_BIN

  # --- the declared fields --------------------------------------------------
  env_var=$(drive "$a" 'printf %s "${ADAPTER_ENV-}"') ||
    fail "$a: does not source cleanly"
  [ -n "$env_var" ] || fail "$a: ADAPTER_ENV is empty (nothing points the \
agent at its config dir)"
  # It becomes `export <name>=<dir>`, so it has to BE a variable name.
  case $env_var in
    ''|*[!A-Za-z0-9_]*|[0-9]*) fail "$a: ADAPTER_ENV '$env_var' is not a \
valid environment variable name" ;;
  esac

  base=$(drive "$a" 'printf %s "${ADAPTER_BASE-}"')
  [ -n "$base" ] || fail "$a: ADAPTER_BASE is empty"
  case $base in
    /*) ;;
    *) fail "$a: ADAPTER_BASE '$base' is not absolute (it is resolved from \
whatever directory the agent happened to be started in)" ;;
  esac
  # The base must sit under the sandbox HOME, which proves it is derived from
  # $HOME rather than hardcoded to one person's machine.
  case $base in
    "$H"|"$H"/*) ;;
    *) fail "$a: ADAPTER_BASE '$base' is not under \$HOME" ;;
  esac

  slots=$(drive "$a" 'printf %s "${ADAPTER_SLOTS-}"')
  case $slots in
    0|1) ;;
    *) fail "$a: ADAPTER_SLOTS is '$slots', want 0 or 1" ;;
  esac

  # --- the functions --------------------------------------------------------
  drive "$a" 'command -v adapter_realbin >/dev/null' ||
    fail "$a: defines no adapter_realbin"
  drive "$a" 'command -v adapter_preexec >/dev/null' ||
    fail "$a: defines no adapter_preexec"
  # preexec runs on the launch path with set -eu in force; a non-zero return
  # aborts the launch, and an adapter with no launch-time environment must
  # still succeed rather than falling out of an empty function body.
  drive "$a" 'adapter_preexec' || fail "$a: adapter_preexec returned non-zero"

  # --- the pooled agents' extra obligations ---------------------------------
  if [ "$slots" = 1 ]; then
    cf=$(drive "$a" 'printf %s "${ADAPTER_CRED_FILE-}"')
    [ -n "$cf" ] || fail "$a: pooled but declares no ADAPTER_CRED_FILE (the \
pool would have nothing to isolate)"
    case $cf in
      */*) fail "$a: ADAPTER_CRED_FILE '$cf' has a path separator; it is a \
name within the config dir" ;;
    esac
    pm=$(drive "$a" 'printf %s "${ADAPTER_PROC_MATCH-}"')
    [ -n "$pm" ] || fail "$a: pooled but declares no ADAPTER_PROC_MATCH (a \
lease could be reclaimed from a live session after a pid is reused)"
    # The cred file must never be listed as shared or seeded -- either would
    # copy or link the very file the pool exists to keep private.
    for lst in ADAPTER_STATIC_FILES ADAPTER_SEED_FILES; do
      v=$(drive "$a" "printf %s \"\${$lst-}\"")
      case " $v " in
        *" $cf "*) fail "$a: $lst lists the credential file '$cf'" ;;
      esac
    done
  fi

  # --- adapter_realbin ------------------------------------------------------
  # The documented override wins outright, which is what makes every other
  # test in this suite able to point an adapter at a stub.
  printf '#!/bin/sh\n:\n' > "$T/real/override"; chmod +x "$T/real/override"
  got=$(drive "$a" 'adapter_realbin' "$BINVAR=$T/real/override") ||
    fail "$a: adapter_realbin failed with \$$BINVAR set"
  [ "$got" = "$T/real/override" ] ||
    fail "$a: \$$BINVAR was not honoured (got '$got')"

  # ...but it is VERIFIED, not trusted. A typo'd override used to be handed
  # back unchecked, and the failure surfaced much later and in disguise: the
  # slot-login flow runs the binary with its failure swallowed, so it reported
  # "still cold" rather than "there is nothing there to run".
  for bad in "$T/real/does-not-exist" "$T/real"; do
    rc=0
    err=$(drive "$a" 'adapter_realbin' "$BINVAR=$bad" 2>&1 >/dev/null) || rc=$?
    [ "$rc" != 0 ] ||
      fail "$a: \$$BINVAR='$bad' was accepted without checking it"
    case $err in
      *"$BINVAR"*"not an executable"*) ;;
      *) fail "$a: a bad \$$BINVAR did not explain itself: $err" ;;
    esac
  done
  # A non-executable REGULAR file is the likeliest version of that mistake
  # (a downloaded binary nobody chmod'd).
  printf 'not runnable\n' > "$T/real/noexec"; chmod -x "$T/real/noexec"
  rc=0; drive "$a" 'adapter_realbin' "$BINVAR=$T/real/noexec" \
    >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "$a: a non-executable \$$BINVAR was accepted"

  # THE safety property. The shim is the first thing on PATH -- that is the
  # entire point of a shim -- and it is also, on disk, this engine. Returning
  # it would exec ourselves.
  shim_at "$T/front/$a"
  shim_at "$H/.npm-global/bin/$a"
  got=$(drive "$a" 'adapter_realbin' || true)
  [ "$got" != "$T/front/$a" ] && [ "$got" != "$H/.npm-global/bin/$a" ] ||
    fail "$a: adapter_realbin returned the shim ('$got'); a launch would \
re-enter the engine and fork until something gives out"
  rm -f "$T/front/$a" "$H/.npm-global/bin/$a"

  # Preference order, for the adapters that have a hermetic first choice:
  # a real binary at the agent's own preferred install path is taken ahead of
  # anything PATH would have found.
  case " $NPM_AGENTS " in
    *" $a "*)
      printf '#!/bin/sh\n:\n' > "$H/.npm-global/bin/$a"
      chmod +x "$H/.npm-global/bin/$a"
      printf '#!/bin/sh\n:\n' > "$T/front/$a"; chmod +x "$T/front/$a"
      got=$(drive "$a" 'adapter_realbin') ||
        fail "$a: adapter_realbin found nothing with two candidates present"
      [ "$got" = "$H/.npm-global/bin/$a" ] ||
        fail "$a: preferred install path lost to PATH (got '$got')"
      rm -f "$H/.npm-global/bin/$a" "$T/front/$a" ;;
  esac
done

[ "$_n" -gt 0 ] || fail "found no adapters to check"

# The engine's own view of the set: one adapter file is one agent it knows,
# and that list drives `shim`, `check`, and `doctor`. A file that is not a
# readable adapter must not silently become an agent.
listed=$(sed -n '/^list_agents() {/,/^}/p' "$HERE/bin/valet-key")
[ -n "$listed" ] || fail "could not extract list_agents from bin/valet-key"
count=$(env -i sh -c "set -eu; LIBEXEC=$HERE/libexec; $listed; list_agents" |
        grep -c .)
[ "$count" = "$_n" ] ||
  fail "the engine sees $count agents, the adapter dir holds $_n"

pass "$_n adapters"
