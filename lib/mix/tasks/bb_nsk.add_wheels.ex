# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbNsk.AddWheels do
    @shortdoc "Adds the Balance Bot's two wheels to a robot"
    @moduledoc """
    #{@shortdoc}

    Hangs a `:left_wheel_joint` and a `:right_wheel_joint` off `:base_link`,
    each carrying a `BB.NSK.Wheel` actuator on its DRV8837, and adds the
    `:motor` parameter group the deadband compensation reads.

    After this the wheels can be driven directly, which is the first thing worth
    doing to a new board:

    ```elixir
    BB.Actuator.velocity(MyBot.Robot, :left_wheel, 5.0)
    BB.Actuator.stop(MyBot.Robot, :left_wheel)
    ```

    ## Which wheel is which

    Left and right are the **robot's**, not yours. Standing in front of it
    looking at it, its left is on your right. The PWM channels below are
    confirmed against the hardware by driving each wheel and watching which way
    the robot goes, and this has been got wrong three times — if a wheel turns
    the wrong way, resolve it by driving it and watching rather than by reasoning
    from the schematic.

    ## Example

    ```bash
    mix bb_nsk.add_wheels
    ```

    ## Options

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    """

    use Igniter.Mix.Task

    alias BB.NSK.Igniter, as: NSK

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
          |> BB.Igniter.add_param_group(robot_module, [:motor], motor_params())
          |> NSK.append_to_link(robot_module, :base_link, wheel(:left), {
            :joint,
            :left_wheel_joint
          })
          |> NSK.append_to_link(robot_module, :base_link, wheel(:right), {
            :joint,
            :right_wheel_joint
          })

        {igniter, false} ->
          Igniter.add_warning(igniter, """
          bb_nsk.add_wheels found no `:base_link` in #{inspect(robot_module)}'s
          topology, so it added nothing. Run `mix bb_nsk.install` first.
          """)
      end
    end

    defp motor_params do
      """
      # Measured unloaded, so the figure under the robot's own weight will be
      # higher — which is why it is tunable.
      param(:deadband,
        type: :float,
        default: 0.01,
        min: 0.0,
        max: 0.9,
        doc: "Duty below which the motor doesn't turn, as a fraction of full scale"
      )
      """
    end

    # The track is NOT measured. The heading hold is feedback, so the yaw gain
    # absorbs whatever the real track is and only the *sign* has to be right —
    # what the guess costs is that the gain has no physical meaning.
    #
    # The wheel inertias are a uniform disc, three orders of magnitude below the
    # body's and so of no consequence either way.
    defp wheel(:left) do
      wheel_body("left", "~u(55 millimeter)", forward: 3, reverse: 2, enable: "PE6")
    end

    defp wheel(:right) do
      wheel_body("right", "~u(-55 millimeter)", forward: 5, reverse: 4, enable: "PE11")
    end

    defp wheel_body(side, offset, pins) do
      """
      joint :#{side}_wheel_joint do
        type(:continuous)
        axis(roll: ~u(-90 degree))
        origin(y: #{offset})

        limit(effort: ~u(0.2 newton_meter), velocity: ~u(20 radian_per_second))

        actuator(
          :#{side}_wheel,
          {BB.NSK.Wheel,
           forward_pwm: #{pins[:forward]},
           reverse_pwm: #{pins[:reverse]},
           enable_pin: "#{pins[:enable]}",
           deadband: param([:motor, :deadband])}
        )

        link :#{side}_wheel_link do
          inertial do
            mass(~u(15 gram))

            inertia(
              ixx: ~u(17.33 gram_square_centimeter),
              iyy: ~u(34.67 gram_square_centimeter),
              izz: ~u(17.33 gram_square_centimeter),
              ixy: ~u(0 gram_square_centimeter),
              ixz: ~u(0 gram_square_centimeter),
              iyz: ~u(0 gram_square_centimeter)
            )
          end
        end
      end
      """
    end
  end
else
  defmodule Mix.Tasks.BbNsk.AddWheels do
    @shortdoc "Adds the Balance Bot's two wheels to a robot"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("The bb_nsk.add_wheels task requires igniter.")
      exit({:shutdown, 1})
    end
  end
end
