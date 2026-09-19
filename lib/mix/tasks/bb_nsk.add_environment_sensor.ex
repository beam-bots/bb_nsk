# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbNsk.AddEnvironmentSensor do
    @shortdoc "Adds the base board's HTS221 temperature and humidity sensor"
    @moduledoc """
    #{@shortdoc}

    Adds `BB.NSK.Sensor.Environment` to the robot's `sensors` section, reading the
    HTS221 at `0x5F` on `i2c-0` and publishing `BB.NSK.Message.EnvironmentState`
    on `[:sensor, :environment]`.

    A robot-level sensor rather than one hung off a link, because it reads the
    air and not a frame. That also decides where the readings go: on a link it
    would publish under that link's whole path, and the panel — which subscribes
    to `[:sensor, :environment]` — would never see one.

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

      igniter
      |> Deps.add_dep(@hts221)
      |> NSK.add_robot_sensor(robot_module, :environment, sensor())
    end

    # A robot-level sensor, not one hung off a link. It reads the air rather than
    # anything about a frame, so it has no business in the topology — and the
    # placement decides the publish path: `[:sensor, :environment]` here, against
    # a link's whole chain if it were mounted on one. `BB.NSK.Display.Controller`
    # subscribes to the former, which is how the panel gets a temperature.
    defp sensor do
      """
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
