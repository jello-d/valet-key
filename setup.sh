#!/bin/sh
# setup.sh - install / uninstall / check / test the valet-key package into a
# prefix. The SINGLE entry point a consumer uses (a person, or a provisioning
# layer): valet-key owns its own layout, so nothing outside needs to know where
# bin, libexec, share and man live. The runtime command stays `valet-key`
# (bin/valet-key); this only wires it in and audits the install.
#
#   ./setup.sh install     place the payload and link bin + man into the prefix
#   ./setup.sh uninstall   remove those links and the payload
#   ./setup.sh check       audit the install; [OK]/[FAIL] markers; drift rc
#   ./setup.sh paths       every root this package uses, key<TAB>value
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#
# PLACED, NEVER LINKED INTO SOURCE (shared-notes/_install-placement.md). The
# install is a COPY into one payload tree, `~/.local/share/valet-key`, and the
# only symlinks point BETWEEN installed locations. It used to symlink
# ~/.local/{bin,libexec,share,man} straight into this checkout, which breaks
# for a DEPARTED package: the clone at ~/.cache/tackup/pkgs/valet-key is
# re-cloned on every provision sweep and wiped on demand, so every such link
# dangles and the command silently stops existing.
#
# THE PAYLOAD IS ONE TREE because the command SELF-LOCATES. bin/valet-key
# resolves its own real path and reads `../libexec` from it, so bin, libexec,
# share and man must all sit inside the one payload or the engine resolves into
# an empty one. That invariant is also what makes a checkout, a relocated
# install and a scratch prefix all work unchanged.
#
# POSIX sh, non-privileged. PREFIX (default ~/.local) and the XDG_* vars
# override the destinations, so a test drives it against a scratch dir. The
# RUNTIME setup (shims onto PATH, credential pools) is `valet-key` itself.
set -eu

PKG=valet-key
_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# HOME may be unset under a provisioner or a unit, and every path below derives
# from it, so resolve it before first use rather than inheriting an empty one.
HOME=${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}
export HOME

PREFIX=${PREFIX:-$HOME/.local}
_bin=${XDG_BIN_HOME:-$PREFIX/bin}
_shr=${XDG_DATA_HOME:-$PREFIX/share}
_man=$_shr/man
_cfg=${XDG_CONFIG_HOME:-$HOME/.config}/$PKG
_st=${XDG_STATE_HOME:-$HOME/.local/state}/$PKG

_pay=$_shr/$PKG                    # THE PAYLOAD: a copy of the shipped tree
# THE RETIRED ROOTS, kept as names so install, uninstall and check all remove
# or report the same thing rather than each spelling it. Both are derived from
# the prefix being installed into, so a scratch-prefix run only ever sweeps its
# own scratch copies: the bt-sane trap (a retire path that ignored PREFIX and
# deleted the live venv mid-verification) does not apply to either.
_oldlib=$PREFIX/libexec/$PKG       # was a symlink to the clone's libexec
_oldshims=$_shr/$PKG/shims         # the shims dir, when it lived in the payload
RC=0

# marker contract: plain [OK]/[FAIL]/[WARN] a host styles; coloured at a tty.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _G=$(printf '\033[1;32m'); _R=$(printf '\033[1;31m')
  _Y=$(printf '\033[1;33m'); _O=$(printf '\033[0m')
else _G=; _R=; _Y=; _O=; fi
ok()   { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$1"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$1"; RC=1; }
note() { printf '  %s[WARN]%s %s\n' "$_Y" "$_O" "$1"; }

_ln()   { mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"; }
# Only ever removes a SYMLINK, so a real file somebody put at an install point
# is reported by check rather than deleted here.
_rmln() { if [ -L "$1" ]; then rm -f "$1"; fi; }

_man_pages() { for _m in "$_root"/man/man*/*.[0-9]; do
  [ -e "$_m" ] && printf '%s\n' "$_m"; done; }

# Every root this package uses, machine-readable. The config root indexes only
# SHIPPED data (see _config_index); the machine-local roots are discoverable
# here and in the config-root README, which is the sanctioned substitute for
# symlinking them somewhere a shared config tree would carry them.
do_paths() {
  printf 'bin\t%s\n'     "$_bin/$PKG"
  printf 'payload\t%s\n' "$_pay"
  printf 'man\t%s\n'     "$_man/man1/$PKG.1"
  printf 'config\t%s\n'  "$_cfg"
  printf 'shims\t%s\n'   "${VALET_KEY_SHIMS_DIR:-$_st/shims}"
  printf 'pool\t%s\n'    "${VALET_KEY_POOL_ROOT:-$HOME/.$PKG-pool}"
}

# --- the payload: staged beside the live tree, then swapped atomically -------
_payload_stage() {
  _ps_new=$_pay.new
  _ps_old=$_pay.old
  # EXPANDED AND CHECKED before anything is removed, per the standing rm rule:
  # the value is verified here, while it can still be inspected, rather than
  # handed to `rm -rf` as a variable. Requiring the leaf to be the package name
  # is what stops a mangled prefix aiming this at a parent directory.
  case $_pay in
  /*/"$PKG") ;;
  *) bad "refusing to stage a payload at '$_pay'"; return 1 ;;
  esac
  rm -rf -- "$_ps_new" "$_ps_old"
  mkdir -p "$_ps_new" || { bad "could not create $_ps_new"; return 1; }
  # EVERY dir the command reads, not just bin: the engine self-locates
  # `../libexec` from its own real path, so a payload missing libexec resolves
  # into nothing and every adapter and the slot library disappear.
  for _d in bin libexec share man; do
    [ -d "$_root/$_d" ] || continue
    cp -R "$_root/$_d" "$_ps_new/" || { bad "could not copy $_d"; return 1; }
  done
  [ -f "$_ps_new/bin/$PKG" ] || { bad "staged payload has no bin/$PKG"
    rm -rf -- "$_ps_new"; return 1; }
  # CARRIED ACROSS, for the one case _migrate_shims declines to resolve (shims
  # at both paths, twice over). Without this the swap destroys the very
  # directory the warning just told the user it had left alone. mux carries its
  # venv the same way and for the same reason.
  if [ -d "$_pay/shims" ] && [ ! -e "$_ps_new/shims" ]; then
    mv -- "$_pay/shims" "$_ps_new/shims" || { bad "could not carry shims"
      rm -rf -- "$_ps_new"; return 1; }
  fi
  # The old layout's `share/<pkg>` was a SYMLINK to the clone, so the live
  # "payload" may be a link rather than a directory; -L catches that, where -e
  # alone would miss a dangling one left by a wiped cache.
  if [ -e "$_pay" ] || [ -L "$_pay" ]; then
    mv -- "$_pay" "$_ps_old" || { bad "could not move the old payload"
      return 1; }
  fi
  mv -- "$_ps_new" "$_pay" || { bad "could not swap in the new payload"
    # THE ROLLBACK UNDOES THE SHIMS MOVE TOO: restoring the old tree puts back
    # a payload whose shims have already moved into `.new`, which the next
    # run's first line deletes. The recovery would look complete and lose
    # exactly what it had just carried.
    if [ -e "$_ps_old" ]; then
      mv -- "$_ps_old" "$_pay"
      if [ -d "$_ps_new/shims" ] && [ ! -e "$_pay/shims" ]; then
        mv -- "$_ps_new/shims" "$_pay/shims"
      fi
    fi
    return 1; }
  rm -rf -- "$_ps_old"
}

# --- the config root as an index, for SHIPPED data only ----------------------
# `~/.config/<pkg>/share -> <payload>` so one place answers "what is
# configured": the user's own files plus a door into the shipped defaults,
# without having to read source to learn that an XDG data path exists.
#
# SHIPPED DATA ONLY, and that is a guardrail rather than a preference. A config
# root is designed to be shared between machines, so a link to a machine-local
# root (state, cache, the credential pool) either travels as a dangling dotfile
# or carries one box's state onto another. Those are named by `paths` and the
# README below instead, which a symlink cannot do: a link records where a root
# is on THIS box, a README can say which roots are shared and which are not.
_config_index() {
  [ -d "$_cfg" ] || mkdir -p "$_cfg" || return 0
  ln -sfn "$_pay" "$_cfg/share"
}

_README_MARK="# Generated by $PKG setup.sh. Edits are kept: see the note below."
_config_readme() {
  _cr=$_cfg/README
  # NEVER CLOBBER A FILE A HUMAN TOUCHED. Written when absent, refreshed only
  # while it still carries the marker line we wrote, and otherwise left exactly
  # alone. The failure that matters is not a stale README, it is eating
  # something somebody wrote in their own config directory.
  if [ -e "$_cr" ] && ! grep -qxF -- "$_README_MARK" "$_cr" 2>/dev/null; then
    return 0
  fi
  [ -d "$_cfg" ] || return 0
  # IT NAMES THE DERIVATION, not only today's resolved path: a snapshot of an
  # absolute path is advice that outlives its contract the first time a root
  # moves, while the variable and its default stay true.
  {
    printf '%s\n\n' "$_README_MARK"
    printf 'valet-key roots. SHARED between machines:\n\n'
    printf '  this dir   $XDG_CONFIG_HOME/%s (profiles, dirs, hooks/)\n' "$PKG"
    printf '  share/     a symlink into the shipped payload, below\n\n'
    printf 'PER-MACHINE, and deliberately NOT linked from here, because this\n'
    printf 'directory is meant to be shareable and a link to machine-local\n'
    printf 'state would either dangle elsewhere or carry this box onto it:\n\n'
    printf '  payload    $XDG_DATA_HOME/%s\n' "$PKG"
    printf '             (a copy, replaced on install; edit nothing here)\n'
    printf '  shims      $XDG_STATE_HOME/%s/shims\n' "$PKG"
    printf '             (generated; put first on PATH, see valet-key init)\n'
    printf '  pool       $VALET_KEY_POOL_ROOT, default $HOME/.%s-pool\n' "$PKG"
    printf '             (LIVE CREDENTIALS; never share or copy it)\n\n'
    printf 'Resolved on this machine right now:\n\n'
    do_paths | while IFS="$(printf '\t')" read -r _k _v; do
      printf '  %-10s %s\n' "$_k" "$_v"
    done
  } > "$_cr"
}

# --- the shims dir moved OUT of the payload ----------------------------------
# It used to default inside `$XDG_DATA_HOME/<pkg>/shims`, which is now the
# payload root, so the atomic swap above would destroy it on every install and
# `uninstall`'s `rm -rf` would take it too. Shims are generated state, so they
# belong in the state root, and the move is carried rather than announced: a
# standalone user who pasted the literal PATH line keeps a working `claude`.
_migrate_shims() {
  [ -d "$_oldshims" ] && [ ! -L "$_oldshims" ] || return 0
  mkdir -p "$_st" || return 0
  if [ ! -e "$_st/shims" ]; then
    mv -- "$_oldshims" "$_st/shims" &&
      echo "$PKG: moved shims to $_st/shims (was inside the payload)"
    return 0
  fi
  # SHIMS AT BOTH PATHS. The state copy is the live one and the payload copy
  # is a leftover from before the move, but it is not ours to delete. Leaving
  # it in place would be a LIE, which is how the first version of this was
  # wrong: the swap below replaces the payload wholesale, so "left alone"
  # meant destroyed a moment later. It moves OUT of the destruction path
  # under a name that says what it is.
  _sup=$_st/shims.superseded
  if [ -e "$_sup" ]; then
    note "shims at $_oldshims and $_sup both; resolve them by hand"
    return 0
  fi
  mv -- "$_oldshims" "$_sup" &&
    note "shims were at both paths; the payload copy is now $_sup"
}

do_install() {
  mkdir -p "$_bin" "$_shr"
  # Before staging, so the move is a plain rename rather than a detour through
  # the staged tree. Order is clarity here, not correctness: the carry-across
  # in _payload_stage protects the directory either way, which a mutation
  # swapping these two lines demonstrated by still passing.
  _migrate_shims
  _payload_stage || return 1
  _ln "$_pay/bin/$PKG" "$_bin/$PKG"
  while IFS= read -r _m; do
    [ -n "$_m" ] || continue
    _d=$(basename "$(dirname "$_m")"); _n=$(basename "$_m")
    _ln "$_pay/man/$_d/$_n" "$_man/$_d/$_n"
  done <<EOF
$(_man_pages)
EOF
  _config_index
  _config_readme
  # A LAYOUT SWITCH REMOVES THE OLD LAYOUT, or the stale copy is the
  # two-copies-on-PATH hazard in a different dress.
  _rmln "$_oldlib"
  if [ -d "$_oldlib" ] && [ ! -L "$_oldlib" ]; then
    rmdir "$_oldlib" 2>/dev/null || :
  fi
  echo "$PKG: placed $_pay; linked bin + man into $PREFIX"
}

do_uninstall() {
  _rmln "$_bin/$PKG"
  while IFS= read -r _m; do
    [ -n "$_m" ] || continue
    _d=$(basename "$(dirname "$_m")"); _n=$(basename "$_m")
    _rmln "$_man/$_d/$_n"
  done <<EOF
$(_man_pages)
EOF
  _rmln "$_cfg/share"
  if [ -e "$_cfg/README" ] &&
     grep -qxF -- "$_README_MARK" "$_cfg/README" 2>/dev/null; then
    rm -f "$_cfg/README"
  fi
  # Guarded exactly as the staging path is, and for the same reason.
  case $_pay in
  /*/"$PKG") rm -rf -- "$_pay" ;;
  *) bad "refusing to remove a payload at '$_pay'" ;;
  esac
  _rmln "$_oldlib"
  # The config dir, the state dir and the pool are NOT removed: they are the
  # user's own files, generated shims, and live credentials respectively.
  echo "$PKG: removed $_pay and its links from $PREFIX"
}

do_check() {
  echo "== $PKG (package install) =="
  if [ -d "$_pay" ] && [ ! -L "$_pay" ]; then
    ok "payload is a real tree ($_pay)"
  else bad "payload missing or still a symlink ($_pay)"; fi
  for _d in bin libexec; do
    if [ -d "$_pay/$_d" ]; then ok "payload carries $_d"
    else bad "payload has no $_d (the engine self-locates it)"; fi
  done
  # The links must resolve INTO the payload. Resolving into this checkout, or
  # into a cache clone, is the violation the placement rule exists to catch.
  _c=$(readlink -f "$_bin/$PKG" 2>/dev/null || true)
  case $_c in
    "$_pay"/*) ok "bin/$PKG resolves into the payload" ;;
    "$_root"/*) bad "bin/$PKG resolves into the SOURCE tree ($_c)" ;;
    *) bad "bin/$PKG does not resolve into the payload ($_c)" ;;
  esac
  # NOT a pipeline: `bad` sets RC, and a pipeline would run it in a subshell
  # where that assignment is lost, so a broken man link would print FAIL and
  # still exit 0. The here-doc keeps the loop in this shell.
  while IFS= read -r _m; do
    [ -n "$_m" ] || continue
    _d=$(basename "$(dirname "$_m")"); _n=$(basename "$_m")
    _mc=$(readlink -f "$_man/$_d/$_n" 2>/dev/null || true)
    case $_mc in
      "$_pay"/*) ok "man/$_d/$_n resolves into the payload" ;;
      *) bad "man/$_d/$_n does not resolve into the payload ($_mc)" ;;
    esac
  done <<EOF
$(_man_pages)
EOF
  if [ "$(readlink "$_cfg/share" 2>/dev/null)" = "$_pay" ]; then
    ok "config root indexes the payload ($_cfg/share)"
  else bad "config index missing or stale ($_cfg/share)"; fi
  if [ -e "$_oldlib" ] || [ -L "$_oldlib" ]; then
    bad "retired root still present: $_oldlib"
  else ok "no retired root"; fi
  if [ -d "$_oldshims" ] && [ ! -L "$_oldshims" ]; then
    bad "shims still inside the payload: $_oldshims"
  fi
  # Runtime health (shims routing, credential pools) is `valet-key doctor`, not
  # this: it needs shims on PATH + provisioned pools that install does not make.
}

_U="usage: setup.sh [install|uninstall|check|paths|test|version]"
case "${1:-help}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  paths)     do_paths ;;
  test)      exec sh "$_root/test/run" ;;
  version)   _v=$(git -C "$_root" describe --tags --always 2>/dev/null || true)
             echo "${_v:-$PKG (unversioned)}" ;;
  -h|--help|help) echo "$_U" ;;
  *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2; exit 2 ;;
esac
