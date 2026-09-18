# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbNsk.AddEnvironmentSensor do
    @shortdoc "Adds the base board's HTS221 temperature and humidity sensor"
    @moduledoc """
    #{@shortdoc}

    Puts `BB.NSK.Sensor.Environment` on `:base_link`, reading the HTS221 at
    `0x5F` on `i2c-0` and publishing `BB.NSK.Message.EnvironmentState`.

    **This is the air, not the robot.** The sensor is deliberately placed away
    from the rest of the board so that it reads the room rather than the SoC, so
    it is no measure of how hard the robot is working. Nor is there an
    alternative: the T113 has no thermal zone at all, so
    `/sys/class/thermal/thermal_zone0/temp` does not exist and the SoC's own
    temperature cannot be read.

    Nothing here changes quickly, so it is read every thirty seconds.

    ## It adds a git dependency

    The `hts221` package on Hex is a **different library with a different API**.
    The one this driver speaks to is only on `harton.dev`, so this task puts a
    git dep in your `mix.exs`. That is deliberate and temporary — a prototype
    driver pinned to a branch — and it can become a Hex version later without
    anything else in your project changing.

    ## Example

    ```bash
    mix bb_nsk.add_environment_sensor
    ```

    ## Options

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    """

    use Igniter.Mix.Task

    alias BB.NSK.Igniter, as: NSK
    alias Igniter.Project.Deps

    @hts221 {:hts221, git: "https://harton.dev/james/hts221.git", branch: "main"}

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        schema: [robot: :string],
        aliases: [r: :robot]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      robot_module = BB.Igniter.robot_module(igniter)

      case NSK.link_exists?(igniter, robot_module, :base_link) do
        {igniter, true} ->
          igniter
          |> Deps.add_dep(@hts221)
          |> NSK.append_to_link(robot_module, :base_link, sensor(), {:sensor, :environment})

        {igniter, false} ->
          Igniter.add_warning(igniter, """
          bb_nsk.add_environment_sensor found no `:base_link` in
          #{inspect(robot_module)}'s topology, so it added nothing. Run
          `mix bb_nsk.install` first.
          """)
      end
    end

    defp sensor do
      """
      # Ambient air rather than anything about the robot — the chip is
      # thermally isolated from the rest of the board on purpose.
      sensor(:environment, BB.NSK.Sensor.Environment)
      """
    end
  end
else
  defmodule Mix.Tasks.BbNsk.AddEnvironmentSensor do
    @shortdoc "Adds the base board's HTS221 temperature and humidity sensor"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("The bb_nsk.add_environment_sensor task requires igniter.")
      exit({:shutdown, 1})
    end
  end
end
