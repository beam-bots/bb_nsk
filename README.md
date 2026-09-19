<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

<img src="https://github.com/beam-bots/bb/blob/main/logos/beam_bots_logo.png?raw=true" alt="Beam Bots Logo" width="250" />

# BB NSK

[![CI](https://github.com/beam-bots/bb_nsk/actions/workflows/ci.yml/badge.svg)](https://github.com/beam-bots/bb_nsk/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache--2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Hex version badge](https://img.shields.io/hexpm/v/bb_nsk.svg)](https://hex.pm/packages/bb_nsk)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/bb_nsk)
[![REUSE status](https://api.reuse.software/badge/github.com/beam-bots/bb_nsk)](https://api.reuse.software/info/github.com/beam-bots/bb_nsk)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/beam-bots/bb_nsk)

[Beam Bots](https://github.com/beam-bots/bb) board support for the Nerves
Starter Kit and its Balance Bot add-on — a two-wheeled self-balancing robot with
an e-paper panel, four NeoPixels and a web interface you drive it from.

Two halves. The drivers and control loops that are the same on every one of
these boards ship as modules; everything a particular robot gets to choose is
written into your project by an Igniter task.

## Installation

```bash
mix igniter.new my_bot --with nerves.new --with-args="--target trellis" \
  --install bb_nsk
cd my_bot
```

Then add subsystems one at a time, each leaving a robot that does something it
couldn't before:

```bash
mix bb_nsk.add_wheels   # its wheels turn
mix bb_nsk.add_imu      # it knows which way up it is
mix bb_nsk.add_balance  # it stands up
```

Or skip to the end:

```bash
mix bb_nsk.cheat
```

Build and burn:

```bash
MIX_TARGET=trellis mix firmware
MIX_TARGET=trellis mix burn
```

## Tasks

| Task | What it adds | What the robot can then do |
|---|---|---|
| `bb_nsk.install` | Nerves system, device tree provisioning, robot module, persistent parameters | boot on the right device tree |
| `bb_nsk.add_wheels` | two DRV8837 wheel actuators and the motor deadband parameter | drive its wheels |
| `bb_nsk.add_imu` | BMI323, a Mahony filter, and the lean and heading sensors | say which way up it is |
| `bb_nsk.add_balance` | the balance loop, its states, its commands and its gains | stand up |
| `bb_nsk.add_leds` | the NeoPixel state indicator | show its state across the room |
| `bb_nsk.add_display` | the e-paper panel and the status screen | draw its own status |
| `bb_nsk.add_environment_sensor` | the base board's HTS221 | report the air around it |
| `bb_nsk.add_wifi` | an access point it brings up when it has no network to join | be reached with nothing configured |
| `bb_nsk.add_web` | Phoenix, a dashboard, a drive pad and a wifi setup page | be driven from a phone |
| `bb_nsk.cheat` | all of the above, in order | — |
| `bb_nsk.doctor` | nothing; run it **on the board** | tell you which of five things is missing |

Every `add_*` task takes `--robot`, and every one is safe to run twice.

## Hardware

| | |
|---|---|
| SoC | Allwinner T113-S4 (dual Cortex-A7, `armv7`) |
| Nerves system | [`nerves_system_trellis`](https://hex.pm/packages/nerves_system_trellis) `~> 0.5` |
| Device tree | `nsk-balance-bot`, selected by the provisioning this installs |
| Motors | two N20 gearmotors through a DRV8837, on `pwmchip0` channels 2–5 |
| IMU | BMI323 at `0x68` on `i2c-0` |
| LEDs | four NeoPixels on `ledc` |
| Display | 4.2" 400x300 e-paper, UC8276 controller, one bit per pixel |
| Environment | HTS221 at `0x5F` on `i2c-0` |

**The device tree is the thing that goes wrong.** `nerves_system_trellis` ships
three, and U-Boot picks by name; the stock choice reaches none of the add-on
board. `bb_nsk.install` writes the provisioning that selects the right one, and
`mix bb_nsk.doctor` says so when a board came up without it.

## Requirements

- Elixir 1.19 or later
- A Nerves project targeting `:trellis`
- `nerves_system_trellis ~> 0.5` — 0.4 and earlier have no balance bot device
  tree at all, and crossing to 0.5 needs a FEL reflash rather than `mix upload`

`bb_nsk.add_display` and `bb_nsk.add_environment_sensor` add git dependencies —
`eink`, `emerge` and `hts221` are prototype drivers not yet on Hex.

## Known limitations

- **No simulation.** A generated project needs the hardware; it won't boot on
  your laptop yet.
- **No odometry, and no position hold.** There are no encoders, so two of the
  four states an inverted pendulum has are unobservable. It balances while
  drifting.
- **No buttons or battery telemetry.** Both are behind the v1 board's STM32,
  whose wire format is undocumented, and the MCU is being dropped from the final
  kit.

## Related packages

- [`bb`](https://github.com/beam-bots/bb) — the robotics framework
- [`bb_sensor_bmi323`](https://github.com/beam-bots/bb_sensor_bmi323) — the IMU driver
- [`bb_estimator_ahrs`](https://github.com/beam-bots/bb_estimator_ahrs) — the orientation filters
- [`bb_parameter_store_cubdb`](https://github.com/beam-bots/bb_parameter_store_cubdb) — parameter persistence
- [`bb_liveview`](https://github.com/beam-bots/bb_liveview) — the dashboard the web interface mounts

## Acknowledgements

- Gus Workman and [Protolux Electronics](https://github.com/protolux-electronics)
  for the Nerves Starter Kit, and for the `eink` driver the panel is drawn through
- [Frederic Cambus](https://www.cambus.net/) for the Spleen font the panel is set in
- The [Emerge](https://github.com/emerge-elixir) project, which rasterises the
  panel's screens

## Licence

Apache-2.0. See `LICENSE.txt`.
