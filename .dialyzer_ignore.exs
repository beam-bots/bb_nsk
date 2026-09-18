# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

# `hts221` and `eink` are git dependencies, which a Hex package cannot declare
# at all — `bb_nsk.add_environment_sensor` and `bb_nsk.add_display` add them to
# the consumer's `mix.exs` instead. So the modules genuinely are not here when
# dialyzer runs, and it is right to say so; there is just nothing to be done
# about it short of those two libraries reaching Hex.
#
# Everything else optional is declared as a dependency so that dialyzer gets the
# types: `emerge`, `video_interop` and `vintage_net` are all on Hex. Only these
# two are unreachable.
# `eink` needs no entry: its calls sit behind a `Mix.target() == :host` guard,
# so on the host dialyzer analyses the branch that does not reach it.
[
  {"lib/bb/nsk/sensor/environment.ex", :unknown_function}
]
