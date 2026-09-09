# libexec/adapter.sh - helpers shared by every adapter. Sourced by the engine
# BEFORE the adapter (which is itself sourced), so an adapter is only the facts
# that differ between agents, not a fourth copy of the logic that does not.
#
# It lives beside the adapters rather than among them because
# libexec/adapters/* is an enumeration: one file there is one agent valet-key
# knows about (list_agents), and a shared fragment sitting in that directory
# would become a phantom agent in `shim`, `check` and `doctor`.

# realbin_from <agent> [preferred path]... -- print the REAL binary for <agent>
# and return 0, or return non-zero if there is none to run.
#
# The order is: the $<AGENT>_BIN override, then the adapter's preferred install
# locations, then PATH in the user's own order. Every candidate is checked
# against $VALET_KEY_SELF -- the resolved engine -- and skipped if it matches.
#
# That skip is the load-bearing part. The shim IS this engine, and it is first
# on PATH by design; exec'ing it would re-enter the engine, which would resolve
# the binary again and find the shim again. The process would fork itself until
# something gave out. Every adapter needs the check, which is exactly why it
# should not be written four times.
realbin_from() {
  _rb_agent=$1; shift

  # The explicit override wins outright -- but it is VERIFIED, not trusted. A
  # typo'd path used to sail through here and only surface much later, as the
  # slot-login flow reporting "still cold" with no hint that the binary it
  # tried to run does not exist. Someone who sets this is making a claim about
  # their box; if the claim is wrong, say so now.
  eval "_rb_over=\${$(printf '%s' "$_rb_agent" | tr 'a-z-' 'A-Z_')_BIN:-}"
  if [ -n "$_rb_over" ]; then
    # -f as well as -x: a DIRECTORY is "executable" to test(1), so a path that
    # points at a folder would otherwise sail through and fail at exec time.
    if [ ! -f "$_rb_over" ] || [ ! -x "$_rb_over" ]; then
      _rb_var=$(printf '%s' "$_rb_agent" | tr 'a-z-' 'A-Z_')_BIN
      echo "valet-key: \$$_rb_var is set to '$_rb_over'," \
           "which is not an executable file" >&2
      return 1
    fi
    printf '%s\n' "$_rb_over"; return 0
  fi

  for _rb_c in "$@"; do
    [ -f "$_rb_c" ] && [ -x "$_rb_c" ] || continue
    [ "$(readlink -f "$_rb_c" 2>/dev/null)" = "${VALET_KEY_SELF:-}" ] &&
      continue
    printf '%s\n' "$_rb_c"; return 0
  done

  # FOLLOW PATH, in the user's order, so a version manager (nvm, asdf) or a
  # local install wins the same way it would if valet-key were not here.
  _rb_oifs=$IFS; IFS=:
  for _rb_d in $PATH; do
    IFS=$_rb_oifs
    [ -n "$_rb_d" ] || continue
    [ -f "$_rb_d/$_rb_agent" ] && [ -x "$_rb_d/$_rb_agent" ] ||
      { IFS=:; continue; }
    if [ "$(readlink -f "$_rb_d/$_rb_agent" 2>/dev/null)" \
         != "${VALET_KEY_SELF:-}" ]; then
      printf '%s\n' "$_rb_d/$_rb_agent"; return 0
    fi
    IFS=:
  done
  IFS=$_rb_oifs
  return 1
}
