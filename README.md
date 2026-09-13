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
slots shares your real config back by symlink — the same projects, the same
settings — while keeping the credentials file private per slot. Sessions stop
clobbering each other. You log into a slot once and stay logged in.

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

`setup.sh` is the single entry point for the package itself: `install`,
`uninstall`, `check` (audit the links, non-zero on drift), `test` (run the
in-repo suite), and `version`. It links rather than copies, so a `git pull` in
the clone is the upgrade. `PREFIX` (default `~/.local`) and the `XDG_*`
variables choose where the links land.

Man pages install to `share/man/man1/`; put that on your `MANPATH` for
`man valet-key`.

## Quickstart

```sh
# one account, stay-logged-in, zero config:
valet-key shim claude
valet-key provision claude      # slots for ~/.claude, in ~/.valet-key-pool
claude                          # every session now leases its own slot

# a second profile, chosen by directory. `provision` needs the profile's
# config dir to exist, so create it first -- it is where the account lives:
printf 'work ~/work\n' > ~/.config/valet-key/profiles
mkdir -p ~/.claude-work         # the work account's own config dir
valet-key provision claude work
cd ~/work && claude             # -> work profile + its pool (log in once)
cd ~      && claude             # -> personal

# warm a couple of slots so the first sessions skip the login:
valet-key login                 # log into the next cold slot (agent: claude)
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
  directories (projects, plugins, ...), its user-edited settings, and its
  append-only prompt history back to the real config, so work done in a slot
  lands in the real account — and up-arrow recall is the same from every slot
  rather than a different past per slot. Sharing is decided by *can concurrent
  writers corrupt it*, not by who writes it: an append-only log qualifies
  because appends don't conflict. The
  credentials file is never shared — that is the isolation target — and neither
  are runtime lock files, which have to be per-slot or a stalled lock wedges
  every session at once. Anything else a slot writes is simply born there.
- **Lazy login.** Slots ship cold. The first session to reach a cold slot logs
  in once; it's warm forever after. You pay only for the concurrency you use.
  A launch prefers a **warm** slot over a cold one, so you're only asked to
  sign in when every warm slot is genuinely busy.
- **Automatic reclaim.** A lease is held by the session's PID and freed when
  that process ends. A dead holder is reclaimed on the next lease, guarded by a
  liveness and command-name check so PID reuse can't steal a live slot.
  Recycling is serialised per pool: judging a PID dead and then acting on it is
  a read-then-write, and two sessions doing it at once could otherwise land on
  the same slot — which would put them back on one shared credentials file.
- **Graceful overflow.** If every slot is leased, the launch falls back to the
  base config dir. It degrades to today's behaviour; it never fails.
- **Shared state, without a shared file.** Some things an agent records aren't
  per-session at all — Claude Code keeps per-project trust, allowed tools and
  MCP approvals in `.claude.json`. That file can't be symlinked (the agent
  rewrites it constantly, so sessions would clobber each other), so each slot
  gets its own copy and `valet-key reconcile` converges them across the pool.
  A launch reconciles the slot it's about to use, so you answer "do you trust
  this folder?" once rather than once per slot. The merge is last-writer-wins
  per project, never a union — otherwise revoking trust on one slot would be
  quietly undone by a stale copy on another.
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
valet-key resolve [agent]          dry run: which profile/pool applies HERE
valet-key reconcile [agent [profile]]   share agent-written state pool-wide
valet-key doctor                   environment health: PATH, creds, saturation
valet-key shim <agent>...          make `<agent>` route through valet-key
valet-key unshim <agent>... | shims | init | shims-dir | rehash
```

**`resolve`** is the dry run: it reports which profile and pool a launch from
this directory would use, shows the working (which hook answered, which were
never asked, what each guard says), and launches nothing. It exits non-zero if
a guard would refuse, so `valet-key resolve && something` means what it looks
like. Reach for it whenever routing surprises you.

Three diagnostics, split by what they can fix. **`check`** audits the
*provisioned* state (pools present, slot counts, structural drift), across the
whole setup when given no argument; it exits non-zero on drift, including a
pool smaller than the `N` you last provisioned, or one holding a surplus slot
that `provision` would have removed. A surplus slot that's warm or in use
isn't drift — `provision` keeps those on purpose, and a failure you can't
clear by re-provisioning isn't one `check` should raise.
**`doctor`** sweeps the *live environment* `check` can't touch: whether each
agent command actually routes through valet-key (the shim wins on `PATH`),
whether an API key in your shell is shadowing a slot's login, whether a pool
is saturated (the next launch would overflow to the shared base), whether any
slot is near its cap, whether a profile you can actually reach has **no pool
at all** (with none, every session for it shares one credentials file — the
original problem, back again, and `check` can't see it because it audits pools
that exist), and whether the hooks you installed are actually being read. It's
read-only, and it exits non-zero only on a *breakage* — a shim that doesn't
intercept, or a hook that isn't running or is answering outside its contract.
The rest are advisories, so a red line always means something is broken.

## Which profile a command acts on

A profile named on the command line is used as given. Omitted, it is
**resolved from where you are**, exactly as a launch would resolve it — so
`provision`, `check`, `login` and `resolve` run inside a work tree all act on
the *work* pool. Each of them prints the pool it settled on, because a
resolution you can't see is one you can't check.

## Configuration

- **`VALET_KEY_CONFIG`** is the config dir: the `profiles` rules, the optional
  `dirs` overrides, and the optional `hooks/` dirs. Default
  `$XDG_CONFIG_HOME/valet-key`, else `~/.config/valet-key`.
- **`VALET_KEY_HOOKS`** is the hooks root (`profile.d/`, `guard.d/`). Default
  `$VALET_KEY_CONFIG/hooks`.
- **`VALET_KEY_SHIMS_DIR`** is where shims live; put it first on `PATH`.
  Default `$XDG_DATA_HOME/valet-key/shims`, else
  `~/.local/share/valet-key/shims`.
- **`VALET_KEY_DEFAULT_PROFILE`** is the unmatched fallback. Default
  `personal`.
- **`VALET_KEY_POOL_ROOT`** is the slot-pool root. Default `~/.valet-key-pool`.
- **`VALET_KEY_SLOT_STALE_DAYS`** is the cap-warning window. Default `7`.
- **`VALET_KEY_VERBOSE`** forces the `valet-key: <agent> profile=... config=...`
  launch line back on for an adapter that declares itself quiet (`gcloud`, whose
  callers parse its stderr). Loud adapters print it anyway.
- **`NO_COLOR`** keeps the `check` / `doctor` / `setup.sh` markers plain. They
  are plain when piped regardless, so this is only for a colour-free terminal.
- **`<AGENT>_BIN`** overrides an adapter's resolved binary, for an odd install
  or a test (`CLAUDE_BIN`, `CODEX_BIN`, ...).

Pool size is the `N` argument to `provision` (default `5`), not an env var.
`provision` **converges** on `N`: re-run it with a smaller number and the
surplus cold slots are removed, so it is a resize rather than a high-water
mark. A surplus slot that is leased or warm is kept and reported instead —
a live session is using the one, and the other holds a login you sat through a
browser flow for.
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

### Hooks: the two questions valet-key cannot answer

**You may not need any.** With no hooks valet-key runs a single `personal`
profile, consults the `profiles` cwd table if you wrote one, and never refuses
anything. That is a complete, working setup. Hooks exist for the two decisions
where a directory table is the wrong instrument.

**1. Which profile applies here?** The built-in answer infers it from *where
you are*. That works until the thing that decides isn't a location: which
cluster you are pointed at, which client's remote this repo has, which unix
group the process holds. Those change without you moving, and a directory
cannot express them.

**2. May this launch at all?** The built-in answer is "always". Sometimes a
launch is *coherent* only under conditions valet-key has no view of — a
reachable network, a mounted volume, an identity you hold. Launching anyway
doesn't fail cleanly; an agent that can't reach something improvises around it.

These are **different questions**, and that is why there are two seams rather
than one hook answering both. A veto is not a profile name, and a selection
cannot say "stop". Keeping them separate means a veto-only integration writes
one file and says nothing about profiles.

A hook's **directory is the verb** — no argument to dispatch on, no case
statement, nothing to implement for a question you don't care about:

```
~/.config/valet-key/hooks/
  profile.d/10-git-remote      # route by the repo's remote
  profile.d/20-kube-context    # route by the active cluster
  guard.d/10-vpn               # refuse work profiles with the VPN down
  guard.d/20-battery           # warn when unplugged
```

Annotated versions of all four ship in `share/hooks/` — copy, chmod +x, edit.
Nothing there is installed.

#### Selection: first to *answer* wins

Hooks run in name order until one answers. The **exit status** says whether it
did:

| exit | output | meaning |
| --- | --- | --- |
| `0` | a name | that profile; the chain stops |
| `0` | empty | "definitely the default here" — also an answer, chain stops |
| non-zero | (ignored) | "I cannot tell" — try the next hook |

Only non-zero passes along; when every hook abstains, the `profiles` table
runs. That third row is the one people miss, and it is the reason the status
carries the meaning rather than the output: a hook that *knows* the answer is
the baseline can say so, instead of inventing a token for the default. And a
**broken** hook cannot be mistaken for one that deliberately said "baseline" —
it exits non-zero, which means "cannot tell", so selection moves on instead of
silently adopting a wrong answer.

Order is precedence, like `PATH`. Two hooks may legitimately disagree; you
decide which is authoritative by naming them.

#### Veto: any refusal wins

**Every** guard runs, and the strictest verdict decides: any `1` refuses, else
any `2` warns, else proceed. A guard that cannot run counts as a refusal — a
safety check that failed has not cleared anything, and failing open is the one
direction this must not fail.

That composition is what makes guards additive. A VPN check and an
account-boundary check are two files that never mention each other, and adding
a third can only make things stricter — no hook can cancel another's refusal.
Each owns its own message; its stderr passes through to you.

The chosen profile arrives as `$1` and in `$VALET_KEY_PROFILE`; the agent is in
`$VALET_KEY_AGENT`. Guarding only some profiles is up to the hook.

#### Where hooks come from

valet-key ships none, and nothing installs any. A hook names tools *your* box
runs, so it belongs to whoever configures the box — you, or your provisioning
layer. `valet-key doctor` checks whatever it finds: that selectors answer
quietly and return a usable name, that guards exit inside the documented
range, and that every file in a hooks directory is executable — one without
the bit is skipped in silence by both seams, so it looks installed and has
never run. It also fails on a leftover `$VALET_KEY_CONFIG/context`, the
single-file hook these two directories replaced: nothing reads it any more,
and a file that looks wired while enforcing nothing is the worst state this
seam has.

> **A guard is a reminder, not a wall.** It reflects and refuses; it does not
> enforce. If you need a real boundary — say, a zero-data-retention tree one
> account must never read — enforce it in the OS (ownership, an ACL, a
> namespace) in whatever supplies the hook. valet-key can say *no*; it cannot
> *be* the lock, and a guard that is the only thing standing between an account
> and a file is a guard you will eventually route around.

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
(or `man -l man/man1/valet-key.1` from a checkout, before installing).

## Status and license

valet-key is stable and in daily use. It is published as a standalone project
extracted from a personal environment repository. Licensed under Apache-2.0;
see `LICENSE`.

## Development

The test suite is POSIX shell with no dependencies beyond a shell and the
checkout. Run it with either:

    ./setup.sh test        # or: sh test/run

Each `test/*.t` is also runnable alone (`sh test/resolve.t`). They work in a
scratch directory and touch nothing on the box: no pool, no config, and no
`$HOME` outside the sandbox.

An 80-column limit is enforced by a tracked pre-commit hook. Enable it once
per clone:

    git config core.hooksPath .githooks

`test/lint.t` checks the same limit, plus `sh` syntax and the executable bit,
across every tracked file, so a commit landed with `--no-verify` still shows up
in the suite.
