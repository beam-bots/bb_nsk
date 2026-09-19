<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project Overview

`bb_nsk` is board support for Gus Workman's Nerves Starter Kit and the Beam Bots
Balance Bot add-on. It contains two things:

1. **Service modules** under `BB.NSK` — drivers and control loops that are the
   same on every one of these boards.
2. **Igniter tasks** under `Mix.Tasks.BbNsk` — a base installer plus one task per
   subsystem, so the package can be installed a piece at a time.

The design and its reasoning are in
[proposal 0024](https://github.com/beam-bots/proposals). The prototype it was
ported from is `goatzen`, whose `CLAUDE.md` carries the pin map, the device tree
notes and the tuning measurements.

## Build and Test Commands

```sh
mix check --no-retry          # everything: compile, test, format, credo, dialyzer, reuse
mix test
mix test path/to/test.exs:42
mix format
```

## Hardware facts that bite

**Every direction is the robot's, never the observer's.** The model follows
REP-103 — +X forwards, +Y to the robot's left, +Z up — and forwards is the face
that points at the ceiling when the robot is laid on its back. This has been got
wrong three times: the IMU's +Y, the wheels' left and right, and which way the
motors turned. When a direction is in doubt, resolve it with the gravity vector
or by driving a wheel and watching, not by reasoning from a drawing.

**The add-on is unreachable without the right device tree.** `nerves_system_trellis`
ships three, and U-Boot picks by name from `fit_config`. The stock value is
`nerves-starter-kit`, which has no PWM, no `i2c0` on PE2/PE3 and no `ledc`. The
installer writes `config/provisioning.conf` to set `nsk-balance-bot`. A board
burned before that can be fixed live:

```elixir
Nerves.Runtime.KV.put("fit_config", "nsk-balance-bot")
```

**The robot falls in 68ms.** An inverted pendulum diverges as `e^(t/tau)` with
`tau = sqrt(L/g)`, and the centre of mass is 45.5mm above the axle. That is what
makes a small balance bot violent rather than gentle, and it is why the loop runs
at 200 Hz and why nothing in it may reach a NIF for arithmetic this small.

**There is no encoder anywhere on this robot.** The wheels are open loop, so
`Command.Position` and `Command.Effort` are refused rather than faked, and there
is no odometry.

## Conventions

Follows the Beam Bots satellite skeleton: SPDX headers on every file (`reuse
lint` runs in CI), `git_ops` releases from conventional commits, `mix check`
as the quality gate.

Comments explain **why**, never what. The tuning notes — which gains were swept,
what the sweep found, which sign conventions are confirmed on hardware — are the
most valuable thing in this package and belong next to the code they justify.
Running commentary on what was tried does not.

## Code Map

| Path | Purpose |
|---|---|
| `lib/bb/nsk/pwm.ex` | sysfs PWM on the Allwinner `pwmchip0` |
| `lib/bb/nsk/wheel.ex` | `BB.Actuator` driving one wheel through a DRV8837 |
| `lib/bb/nsk/sensor/lean.ex` | the `:lean` joint's angle, from the fused orientation |
| `lib/bb/nsk/sensor/heading.ex` | the `:ground` joint's yaw, from the gyroscope |
| `lib/bb/nsk/balance/controller.ex` | the balance loop, its trim and its heading hold |
| `lib/bb/nsk/command/` | `arm`, `stand`, `fall` and `poweroff` handlers |
| `lib/bb/nsk/drive.ex` | a pilot's throttle and turn, over pubsub |
| `lib/bb/nsk/igniter.ex` | topology surgery the `add_*` tasks share |
| `lib/mix/tasks/` | the installer, its subsystem tasks, `cheat` and `doctor` |
| `test/support/robot.ex` | the reference robot the tasks are checked against |

`test/support/robot.ex` is the same robot the tasks generate, minus the IMU —
the BMI323 driver stops rather than declining when the chip isn't there, which
on the host would take the supervision tree with it. **If you change what a task
emits, change it there too.** The end-to-end state machine test runs against it,
so a drift between the two is a test that passes against a robot nobody has.

## What the tasks build

`bb_nsk.install` establishes the robot module and the device tree provisioning;
the seven `add_*` tasks each attach one subsystem; `bb_nsk.cheat` composes them.
Every task is idempotent, and `cheat` produces a byte-identical robot to running
them one at a time — there is a test for that, and it is the thing most likely
to break silently.

### Igniter, and what does not work

Learned the hard way, and worth not rediscovering:

- **`adds_deps:` does not reliably reach `mix.exs` from a composed task.** It
  exists to fetch and compile something *before* the task runs. For a dependency
  that just needs to be in the consumer's project, call `Deps.add_dep/2` in
  `igniter/1`. `bb_nsk.cheat` once produced a project with none of the display
  or wifi dependencies because of this.
- **A package added during a run is not on the code path for that same run.**
  Neither `adds_deps:` nor `installs:` changes that from a composed task, so
  `compose_task/2` cannot reach its installer. Anything whose *tasks* are needed
  has to be a real dependency — which is why `bb_liveview` and
  `bb_parameter_store_cubdb` are, and why `bb_nsk.add_web` requires `phx_install`
  to already be there rather than adding it.
- **A failed compose aborts the whole run and rolls back everything**, including
  `mix.exs` changes made earlier in the same pass. A task that half-works leaves
  no trace, which makes this hard to diagnose from the outside.
- **`adds_deps:` and `Deps.add_dep/2` do different halves of the job.** The first
  fetches and compiles during the run but does not write to the consumer's
  `mix.exs`; the second writes but does not fetch. `bb_nsk.install` declares
  `phx_install` both ways, which is what lets `bb_nsk.cheat` run straight
  afterwards without `mix deps.get` in between.
- **Router and page additions have to be guarded by hand.** `bb_liveview.install`
  appends its dashboard scope every time it runs, and a second `live_session` of
  the same name is a compile error. Igniter's Phoenix extension also relocates a
  generated LiveView into `live/` *after* creating it, so an `on_exists: :skip`
  against the path it was asked for sees nothing on a second run and writes the
  page again under a name the first one already has. Skip on the module, not the
  path.
- **`bb_nsk.install` adds `phx_install` so that `bb_nsk.add_web` can compose it.**
  That is the whole reason it is in the base installer rather than in the task
  that wants it.
- **`Igniter.Project.TaskAliases` cannot write a function reference.** Its
  typespec accepts `{:code, ast}`, at the top level or inside a list, and both
  are written into `mix.exs` as a literal `{:code, ...}` tuple, which Mix then
  rejects. The way out is not to need one: `bb_nsk.prune_nifs` and
  `bb_nsk.restore_nifs` are ordinary Mix tasks, so the aliases are plain strings.
  That is also what a person reading the `mix.exs` would rather see.

### Assets

A Nerves release is assembled by `mix firmware`, which has no idea Phoenix is
here — so nothing builds `priv/static` unless the `firmware` alias is made to.
`bb_nsk.add_web` prepends `assets.deploy` to it.

Which in turn means `esbuild` and `tailwind` run *during a target build*, so
they are left exactly as `phx.install` declares them: `runtime: Mix.env() ==
:dev`, which is also what `bb_liveview` uses. Anything narrower puts them out of
reach of the firmware build — `targets: :host` and `only: [:dev]` were both tried
and both fail, the latter because Nerves refuses a dependency scoped more
narrowly than its dependent. They cost about 56K in the image and no binaries.

### Phoenix on Nerves

`bb_nsk.add_web` composes the five `phx.install.*` subtasks directly rather than
`mix igniter.install phx_install`. The orchestrator adds `gettext ~> 0.26` to the
project regardless of `--no-gettext` — the flag gates the generator, not the
dependency — and `bb` reaches `localize`, which wants `~> 1.0`. The two cannot
be resolved together.

Three more things a board needs that a server does not, each found by a firmware
build failing:

- `esbuild` may **not** be scoped `targets: :host`. `bb_liveview` depends on it
  for every target, and Nerves refuses a dependency narrower than its dependent.
  Only `runtime: false` can be applied from here.
- Dev/test-only dependencies should carry `only:` and **no** `targets:`. They are
  already absent from firmware, and the extra restriction triggers the same
  conflict — `sourceror` hit it through `ex_ast`.
- `phx.install` writes live-reload patterns as plain `~r"..."`. A regex in
  compile-time config needs the `E` modifier to survive being written into a
  release, and only Nerves builds a release out of `:dev`.

`bb_nsk.doctor` runs on the board and checks the five things that account for
nearly every failure. Four of its five checks fail together when the device tree
is wrong, which is what its advice leads with.
