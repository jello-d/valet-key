# valet-key

**Persistent, location-aware logins for your coding agents.**

valet-key is a launcher for coding-agent CLIs like Claude Code, Codex, and
Gemini. It sits in front of the agent you already use and manages its
credentials for you: it keeps each session logged in, and it selects the right
account for wherever you're working. You go on running `claude` exactly as
before; valet-key does its work underneath and hands off to the real tool.

It's POSIX shell: no daemon, and no runtime dependencies beyond the agent
itself.

---

## The problem

If you run Claude Code, or any agent that signs in with a subscription
account, in **more than one session at once**, you've probably hit this:
you're working, and out of nowhere the agent drops you back at a login prompt.
You log in. A while later, it happens again. It looks random.

It isn't. These agents keep your login in a single credentials file, and for
many of them the refresh token is **single-use**: each time the agent refreshes
its access it rotates that token, and the previous one stops working.

With one session, that's invisible. But the moment two sessions share the file
(a terminal and your editor's extension, two git worktrees, a script that
shells out to the agent while you work), one of them refreshes, and the other
is left holding a dead token. Next time that session needs to refresh, it
can't, so it makes you log in, which rotates the token again and knocks out
the first. They take turns logging each other out.

And it's easy to be running "concurrent sessions" without thinking of it that
way: an IDE plugin and a terminal are two sessions. So is a background job.

> **Note:** this bites the subscription / browser login flow, whose token
> rotates. An API-key setup carries no such token to collide over.

**valet-key gives each session its own credentials.** A small pool of login
slots sits beside your real config and shares everything else (projects,
settings, history), so the only thing a session owns privately is its login.
Sessions stop clobbering each other. You log into a slot once and stay logged
in.

The same design turns a liability into a feature: because each session is
isolated, you can **deliberately** run as many in parallel as you like
(worktrees, agents, batch jobs), and none of them disturb the others.

## The right account for where you are

The second thing valet-key handles is **which** account.

Most people who use these agents seriously have more than one login: work and
personal, two clients, a sandbox. valet-key maps each to a named **profile**
and picks the right one from where you are. The built-in rule is a directory
match. A line like `work ~/work` means any session started inside `~/work` (or
its git repo) runs the `work` profile; everything else falls back to
`personal`. Each profile keeps its own credentials, wholly separate, and
accounts never cross.

That's the whole core: **stay logged in, on the right account, everywhere.** It
takes zero configuration for the single-account case, and one line to add a
second profile.

---

## Requirements

- A POSIX shell (`dash` is fine, no bash-isms), `readlink -f`, and standard
  coreutils.
- The agent CLI you want to wrap (e.g. Claude Code).
- Optional: `git`. When present, the resolver treats the git root as the
  context, so a session anywhere in a repo resolves the same way.

## Install

valet-key is a single engine (`bin/valet-key`) that self-locates its helpers.
Install it, put its **shims directory** first on `PATH`, and create one shim
per agent:

```sh
git clone https://github.com/jello-d/valet-key ~/.valet-key
~/.valet-key/setup.sh install   # links valet-key into ~/.local (bin/libexec/..)

eval "$(valet-key init)"        # prints: export PATH="<shims-dir>:$PATH"
valet-key shim claude           # make `claude` route through valet-key
```

`valet-key init` prints the one line to add to your shell profile: the same
shims-dir-first-on-PATH ritual `pyenv`, `rbenv`, and `asdf` use. The shims
directory is separate from `~/.local/bin`, so the shim shadows the real binary
with no collision; valet-key finds the real one past itself.

Man pages install to `share/man/man1/`; put that on your `MANPATH` for
`man valet-key`.

## Quickstart

```sh
# one account, stay-logged-in, zero config:
valet-key shim claude
valet-key provision claude      # a pool of slots beside ~/.claude
claude                          # every session now leases its own slot

# two profiles, chosen by directory:
printf 'work ~/work\n' > ~/.config/valet-key/profiles
valet-key provision claude work # a work pool (beside ~/.claude-work)
cd ~/work && claude             # -> work profile + its pool
cd ~      && claude             # -> personal

# warm a couple of slots so the first sessions skip the login:
valet-key login                 # log into the next cold slot
valet-key login check           # warm/total, days-to-cap per slot
```

## How it works

A **shim** is a symlink named for an agent (`claude`, `codex`) that points at
the valet-key engine. The engine reads its own invoked name to decide which
agent it is: the *multi-call binary* trick from busybox and git. Because the
shim is a real file on `PATH`, it works from anywhere the name is typed,
whether an interactive shell, a script, or an editor. (An alias or shell
function couldn't; an `exec`'d process bypasses those.)

On each launch valet-key **resolves** the profile from your location,
**leases** a free credential slot for that profile, and **execs** the real
agent pointed at it:

```
$ claude
  resolve ─▶ profile: work        (cwd under ~/work, or a rule you supply)
  lease   ─▶ a free login slot     (this session's private credentials)
  exec    ─▶ the real claude, pointed at that slot
```

The pool is the heart of it:

- **Slots share state, own their login.** Every slot symlinks the account's
  projects, plugins, settings, and history back to the real config; the only
  private file is its credentials. Nothing forks except the token.
- **Lazy login.** Slots ship cold. The first session to reach a cold slot logs
  in once; it's warm forever after. You pay only for the concurrency you use.
- **Automatic reclaim.** A lease is held by the session's PID and freed when
  that process ends. A dead holder is reclaimed on the next lease, guarded by a
  liveness and command-name check so PID reuse can't steal a live slot.
- **Graceful overflow.** If every slot is leased, the launch falls back to the
  base config dir. It degrades to today's behaviour; it never fails.
- **Cap awareness.** Where an agent records an absolute token cap that
  refreshing can't extend, `valet-key stale` surfaces slots nearing it so you
  can re-login first.

## Commands

Full reference in **`man valet-key`**. The essentials:

```
claude [args]                      run Claude in the resolved profile, on a slot
valet-key run <agent> [args]       the same, named explicitly
valet-key provision <agent> [profile] [N]     create/refresh a pool (N=5)
valet-key login [warm|check|force|stale] [agent] [profile]    slot logins
valet-key stale                    all pools: warm slots near their token cap
valet-key check [agent [profile]]  audit a pool, or the whole setup (drift)
valet-key doctor                   environment health: PATH, creds, saturation
valet-key shim <agent>...          make `<agent>` route through valet-key
valet-key unshim <agent>... | shims | init | shims-dir | rehash
```

Two diagnostics, split by what they can fix. **`check`** audits the
*provisioned* state (pools present, slot counts, structural drift), across the
whole setup when given no argument; it exits non-zero on drift. **`doctor`**
sweeps the *live environment* `check` can't touch: whether each agent command
actually routes through valet-key (the shim wins on `PATH`), whether an API key
in your shell is shadowing a slot's login, whether a pool is saturated (the next
launch would overflow to the shared base), and whether any slot is near its cap.
It's read-only and fails only on a real breakage (a shim that doesn't
intercept); the rest are advisories.

## Configuration

- **`VALET_KEY_CONFIG`** is the config dir: the `profiles` rules, the optional
  `dirs` overrides, and the optional `context` hook. Default
  `~/.config/valet-key`.
- **`VALET_KEY_SHIMS_DIR`** is where shims live; put it first on `PATH`.
  Default `~/.local/share/valet-key/shims`.
- **`VALET_KEY_DEFAULT_PROFILE`** is the unmatched fallback. Default
  `personal`.
- **`VALET_KEY_POOL_ROOT`** is the slot-pool root. Default `~/.valet-key-pool`.
- **`VALET_KEY_SLOT_STALE_DAYS`** is the cap-warning window. Default `7`.
- **`<AGENT>_BIN`** overrides an adapter's resolved binary, for an odd install
  or a test (`CLAUDE_BIN`, `CODEX_BIN`, ...).

Pool size is the `N` argument to `provision` (default `5`), not an env var.
Size it to your peak concurrent sessions plus a little headroom, and no higher:
overflow just falls back to the base config, so undersizing is cheap, while
oversizing backfires two ways. Idle slots still age toward their token cap
without being refreshed, and a burst of logins can look abusive to the provider.

---

## Advanced

Everything above is the whole point. This section is for when you want more.

### Pin a profile to a specific directory

By default a profile's config lives at `<base>-<profile>` (so `work` becomes
`~/.claude-work`). To put it somewhere specific (a sealed location, or a tool
whose env points at a *home* rather than a config dir), add a
`<agent> <profile> <dir>` line to `$VALET_KEY_CONFIG/dirs`.

### A resolver hook

The built-in resolver matches `$PWD` (or the git root) against the
`<profile> <dir>` lines in `$VALET_KEY_CONFIG/profiles`. If you need richer
logic than a directory match, make `$VALET_KEY_CONFIG/context` executable and
have its `resolve` verb print the active profile name. It overrides the
built-in rule.

The hook's **exit status** says whether it answered:

| exit | output | meaning |
| --- | --- | --- |
| `0` | a name | that profile |
| `0` | empty | "no special context here" -- use the default profile |
| non-zero | (ignored) | "I cannot tell" -- fall back to the built-in rule |

Exit 0 is authoritative, *including* when the output is empty: that is a real
answer, not an abstention, so the directory matcher is skipped. Only a
non-zero exit falls through to it. This means a provider that knows the
context is the baseline can simply say nothing, instead of inventing a token
for the default; and a hook that is broken cannot be mistaken for one that
deliberately said "baseline".

The name is validated as a DNS label (`a-z`, `0-9`, hyphen; no leading or
trailing hyphen; 63 max), because it becomes a directory component and a pool
id. An invalid name is a hard error, never a silent fall back to the default.

### A pre-launch check (guard)

valet-key can run one optional check *before* it launches, and let it **warn**
or **refuse**. Implement the `guard <profile>` verb in
`$VALET_KEY_CONFIG/context`: exit `0` to proceed, `2` to warn and continue, `1`
to refuse and abort. The hook owns the message.

It's a general seam: wire in whatever coherence check you want. One example is
a hard account boundary, where the guard refuses to start the personal account
inside a work tree. But it could gate on anything: a network, a mounted
volume, the time of day.

> **This is a reminder, not a wall.** The guard reflects and refuses; it does
> not enforce. If you need a real boundary (say, a zero-data-retention tree one
> account must never read), enforce it in the OS (ownership, an ACL, a
> namespace) in the integration that supplies the hook. valet-key can say *no*;
> it cannot *be* the lock.

### Adapters: add an agent

An adapter is a small shell fragment, `libexec/adapters/<agent>`,
that declares how one agent stores its identity: the env var that points it at
its config dir, its base dir, whether it needs the slot pool (a single-use
token to isolate) or just profile separation, and which files a slot keeps
private versus shares. Drop a file in, run `valet-key shim <agent>`, and you've
taught valet-key a new tool. Full field reference in `man valet-key`.

**Bundled:**

- **`claude`**: Claude Code. Pooled, because its subscription token is
  single-use, so it needs the slot pool.
- **`codex`**: OpenAI Codex. Pooled; a slot is warmed via `codex login`.
- **`gemini`**: Google Gemini. Poolless, because its refresh token is
  reusable (not rotated on refresh), so profile separation is all it needs.
- **`gcloud`**: not a coding agent at all. Proof that valet-key is a general,
  profile-aware *identity* launcher: `gcloud` uses your work account's config
  inside the work tree and your personal one elsewhere, with no
  `gcloud config configurations activate` dance. Coding agents are just the
  flagship case.

---

## Reference

Complete command, hook, adapter, and environment reference: **`man valet-key`**
(or `man -l share/man/man1/valet-key.1` from a checkout).

## Status and license

valet-key is stable and in daily use. It is being published as a standalone
project extracted from a personal environment repository; a `LICENSE` will
accompany the release.

## Development

An 80-column limit is enforced by a tracked pre-commit hook. Enable it once
per clone:

    git config core.hooksPath .githooks
