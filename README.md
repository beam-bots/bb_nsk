<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

<img src="https://github.com/beam-bots/bb/blob/main/logos/beam_bots_logo.png?raw=true" alt="Beam Bots Logo" width="250" />

# bb_nsk

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache--2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)

Board support for the [Nerves Starter Kit](https://github.com/protolux-electronics)
and its **Beam Bots Balance Bot add-on**: a two-wheeled self-balancing robot
described with [BB](https://hexdocs.pm/bb).

Two halves. The drivers and control loops that are the same on every one of
these boards ship as modules; everything a particular robot gets to choose is
written into your project by an Igniter task.

## Getting started

```sh
mix nerves.new my_bot --target trellis
cd my_bot
mix igniter.install bb_nsk
mix deps.get
```

Then add subsystems one at a time:

```sh
mix bb_nsk.add_wheels   # its wheels turn
mix bb_nsk.add_imu      # it knows which way up it is
mix bb_nsk.add_balance  # it stands up
```

Or skip to the end:

```sh
mix bb_nsk.cheat
```

Build and burn:

```sh
MIX_TARGET=trellis mix firmware
MIX_TARGET=trellis mix burn
```

## Hardware

| | |
|---|---|
| SoC | Allwinner T113-S4 (dual Cortex-A7, `armv7`) |
| Nerves system | [`nerves_system_trellis`](https://hex.pm/packages/nerves_system_trellis) `~> 0.5` |
| Device tree | `nsk-balance-bot` — set by the provisioning this package installs |
| Motors | two N20 gearmotors through a DRV8837, on `pwmchip0` channels 2-5 |
| IMU | BMI323 at `0x68` on `i2c-0` |
| LEDs | four NeoPixels on `ledc` |
| Display | 4.2" 400x300 e-paper, UC8276 |

## Licence

Apache-2.0. See [LICENSE.txt](LICENSE.txt).
