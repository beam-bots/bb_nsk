# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbNsk.AddLeds do
    @shortdoc "Adds the NeoPixel state indicator"
    @moduledoc """
    #{@shortdoc}

    Adds `BB.NSK.Leds.Controller`, which shows the robot's safety state on the
    four NeoPixels: blue disarmed, green ready or balancing, orange disarming,
    magenta flashing when it has fallen over, red for an error.

    They breathe rather than sitting still, which reads as a robot that is
    running rather than one that has locked up — except `:fallen`, which
    flashes, because it is the one state asking the operator for something.

    ## Why this is worth having even with a panel

    The panel says the same thing and takes the better part of three seconds to
    say it. These are immediate, and immediate is what you want from something
    telling you whether the robot is about to move. In a room full of these,
    being readable from wherever you happen to be standing matters more than
    being detailed.

    ## Needs the right device tree

    The `ledc` node is only in the `nsk-balance-bot` device tree, so on a board
    booted with the stock setting there are no pixels to find and the controller
    runs with nothing to drive. `mix bb_nsk.doctor` says so.

    ## Example

    ```bash
    mix bb_nsk.add_leds
    ```

    ## Options

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    * `--brightness` - Top of the pulse, 0-255 (default 40). These are bright
      enough to be uncomfortable at full scale, and draw current to match.
    """

    use Igniter.Mix.Task

    @default_brightness 40

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        schema: [robot: :string, brightness: :integer],
        aliases: [r: :robot]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      robot_module = BB.Igniter.robot_module(igniter)
      brightness = Keyword.get(igniter.args.options, :brightness, @default_brightness)

      BB.Igniter.add_controller(igniter, robot_module, :leds, controller(brightness))
    end

    # Controllers default to `simulation: :omit`, which is what this wants: there
    # are no pixels to drive under simulation, and the controller would spend a
    # timer finding that out twenty times a second.
    defp controller(brightness) do
      """
      controller(:leds, {BB.NSK.Leds.Controller, brightness: #{brightness}})
      """
    end
  end
else
  defmodule Mix.Tasks.BbNsk.AddLeds do
    @shortdoc "Adds the NeoPixel state indicator"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("The bb_nsk.add_leds task requires igniter.")
      exit({:shutdown, 1})
    end
  end
end
