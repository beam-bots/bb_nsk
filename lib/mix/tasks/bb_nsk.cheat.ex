# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbNsk.Cheat do
    @shortdoc "Builds the whole Balance Bot in one go"
    @moduledoc """
    #{@shortdoc}

    Composes every `bb_nsk.add_*` task in order, and does nothing else. Anything
    this can do, the tasks underneath can do one at a time — if that ever stops
    being true it is a bug here.

    ```bash
    mix nerves.new my_bot --target trellis
    cd my_bot
    mix igniter.install bb_nsk
    mix bb_nsk.cheat

    MIX_TARGET=trellis mix firmware
    MIX_TARGET=trellis mix burn
    ```

    Every task it runs is idempotent, so this is safe over a project that is
    already half built — someone who worked through the first few by hand and
    then ran out of time gets the rest and keeps their edits to the rest.

    It does not run `bb_nsk.install`, which has to have added the robot module
    and the device tree provisioning before any of this has anywhere to attach.

    Nor does it bootstrap Phoenix — `bb_nsk.add_web` needs a router to already
    exist, for reasons its own docs explain. The full sequence from nothing:

    ```bash
    mix igniter.install bb_nsk
    mix igniter.install phx_install
    mix bb_nsk.cheat
    ```

    ## Options

    Passed straight through to the tasks underneath.

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    """

    use Igniter.Mix.Task

    # Ordered so that each leaves the robot able to do something it couldn't
    # before: it drives, then it knows which way up it is, then it stands. The
    # rest are what makes it usable in a room — a state light, a screen, a
    # network of its own and a way to drive it from a phone.
    @tasks [
      "bb_nsk.add_wheels",
      "bb_nsk.add_imu",
      "bb_nsk.add_balance",
      "bb_nsk.add_leds",
      "bb_nsk.add_environment_sensor",
      "bb_nsk.add_display",
      "bb_nsk.add_wifi",
      "bb_nsk.add_web"
    ]

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        composes: @tasks,
        schema: [robot: :string],
        aliases: [r: :robot]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      argv = ["--robot", inspect(BB.Igniter.robot_module(igniter))]

      Enum.reduce(@tasks, igniter, &Igniter.compose_task(&2, &1, argv))
    end
  end
else
  defmodule Mix.Tasks.BbNsk.Cheat do
    @shortdoc "Builds the whole Balance Bot in one go"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("The bb_nsk.cheat task requires igniter.")
      exit({:shutdown, 1})
    end
  end
end
