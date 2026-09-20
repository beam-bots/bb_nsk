# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbNsk.AddBalance do
    @shortdoc "Adds the balance loop, its states and its commands"
    @moduledoc """
    #{@shortdoc}

    Adds `BB.NSK.Balance.Controller` and everything it needs: the `:balancing`
    and `:fallen` states, the `stand` and `fall` commands it drives them with, a
    replacement `arm` that lands in the state the robot's attitude calls for,
    and the `:balance`, `:yaw` and `:drive` parameter groups.

    After this the robot stands up. Hold it upright and still, arm it, and let
    go:

    ```elixir
    MyBot.Robot.arm()
    ```

    ## The gains are measured, not guessed

    Every default here came off the robot rather than out of a textbook, and the
    reasoning is in the parameter docs. The two worth knowing before touching
    anything: the proportional and derivative gains live as a *ratio* rather than
    independently, and the catch angle is deliberately tight — at five degrees
    the robot took over while still moving in the operator's hand and spent its
    whole life answering that transient.

    They are parameters rather than constants because nearly all of them were
    found on the floor, and a firmware build per guess is not a tuning session.
    With `bb_parameter_store_cubdb` installed, what you find survives a reboot.

    ## Requires an IMU

    The loop closes around the lean the IMU reports, so this wants
    `mix bb_nsk.add_imu` to have run. It warns rather than proceeding otherwise,
    because a balance loop with nothing to balance against is a robot that
    silently never stands up.

    ## Example

    ```bash
    mix bb_nsk.add_balance
    ```

    ## Options

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    """

    use Igniter.Mix.Task

    alias BB.NSK.Igniter, as: NSK
    alias Igniter.Code.{Common, Function}
    alias Sourceror.Zipper

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
      |> warn_without_imu(robot_module)
      |> BB.Igniter.add_param_group(robot_module, [:balance], balance_params())
      |> BB.Igniter.add_param_group(robot_module, [:drive], drive_params())
      |> BB.Igniter.add_param_group(robot_module, [:yaw], yaw_params())
      |> BB.Igniter.add_controller(robot_module, :balancer, controller())
      |> add_states(robot_module)
      |> add_commands(robot_module)
    end

    defp warn_without_imu(igniter, robot_module) do
      case NSK.entity_in_topology?(igniter, robot_module, :sensor, :lean_angle) do
        {igniter, true} ->
          igniter

        {igniter, false} ->
          Igniter.add_warning(igniter, """
          bb_nsk.add_balance added the loop, but #{inspect(robot_module)} has no
          `:lean_angle` sensor for it to close around, so the robot will arm and
          then never stand up.

              mix bb_nsk.add_imu
          """)
      end
    end

    defp add_states(igniter, robot_module) do
      igniter
      |> add_dsl_entity(robot_module, :states, :state, :balancing, """
      state(:balancing, doc: "Actively holding itself upright")
      """)
      |> add_dsl_entity(robot_module, :states, :state, :fallen, """
      state(:fallen, doc: "Past recovering, wheels braked, waiting to be stood back up")
      """)
    end

    # `arm` is replaced rather than added. `bb.install` writes one that always
    # lands in `:idle`, and a robot armed while already on its side would sit
    # there calling itself idle — showing the same green on the NeoPixels as one
    # standing ready to go. `BB.NSK.Command.Arm` asks the controller where it
    # ought to be instead.
    defp add_commands(igniter, robot_module) do
      igniter
      |> replace_arm(robot_module)
      |> add_dsl_entity(robot_module, :commands, :command, :stand, """
      command :stand do
        handler(BB.NSK.Command.Stand)
        allowed_states([:idle, :fallen])
      end
      """)
      |> add_dsl_entity(robot_module, :commands, :command, :fall, """
      # From `:idle` as well as `:balancing`, because a robot armed while
      # already on its side has fallen over without ever having balanced.
      command :fall do
        handler(BB.NSK.Command.Fall)
        allowed_states([:balancing, :idle])
      end
      """)
      |> widen_disarm(robot_module)
    end

    defp replace_arm(igniter, robot_module) do
      update_command(igniter, robot_module, :arm, """
      command :arm do
        # A custom handler so that arming lands in the state the robot's
        # attitude calls for rather than always in `:idle`. `arm true` keeps
        # `BB.Safety.arm/1` routing through the command system.
        handler(BB.NSK.Command.Arm)
        allowed_states([:disarmed])
        arm(true)
      end
      """)
    end

    # Disarming has to be reachable from every state the robot can get stuck in,
    # or a robot that has fallen over can't be switched off.
    defp widen_disarm(igniter, robot_module) do
      update_command(igniter, robot_module, :disarm, """
      command :disarm do
        handler(BB.Command.Disarm)
        allowed_states([:idle, :balancing, :fallen])
      end
      """)
    end

    defp update_command(igniter, robot_module, name, code) do
      Spark.Igniter.update_dsl(igniter, robot_module, [{:section, :commands}], nil, fn zipper ->
        case find_command(zipper, name) do
          {:ok, found} ->
            {:ok, Zipper.replace(found, Sourceror.parse_string!(code))}

          :error ->
            {:ok, Common.add_code(zipper, code)}
        end
      end)
    end

    defp find_command(zipper, name) do
      case Function.move_to_function_call_in_current_scope(
             zipper,
             :command,
             [2, 3],
             &Function.argument_equals?(&1, 0, name)
           ) do
        {:ok, found} -> {:ok, found}
        _ -> :error
      end
    end

    defp add_dsl_entity(igniter, robot_module, section, entity, name, code) do
      Spark.Igniter.update_dsl(igniter, robot_module, [{:section, section}], nil, fn zipper ->
        case Function.move_to_function_call_in_current_scope(
               zipper,
               entity,
               [1, 2, 3],
               &Function.argument_equals?(&1, 0, name)
             ) do
          {:ok, _} -> {:ok, zipper}
          _ -> {:ok, Common.add_code(zipper, code)}
        end
      end)
    end

    defp controller do
      """
      controller(
        :balancer,
        {BB.NSK.Balance.Controller,
         setpoint: param([:balance, :setpoint]),
         proportional_gain: param([:balance, :proportional_gain]),
         derivative_gain: param([:balance, :derivative_gain]),
         trim_gain: param([:balance, :trim_gain]),
         trim_limit: param([:balance, :trim_limit]),
         fall_angle: param([:balance, :fall_angle]),
         catch_angle: param([:balance, :catch_angle]),
         catch_rate: param([:balance, :catch_rate]),
         yaw_gain: param([:yaw, :gain]),
         yaw_damping: param([:yaw, :damping]),
         yaw_limit: param([:yaw, :limit]),
         yaw_tau: param([:yaw, :tau]),
         drive_limit: param([:drive, :authority]),
         drive_slew: param([:drive, :ramp]),
         drive_release: param([:drive, :release])}
      )
      """
    end

    defp balance_params do
      """
      # Not zero: the centre of mass sits ahead of the wheel axis, so the robot
      # is only in equilibrium leaning back far enough to bring it over them.
      param(:setpoint,
        type: {:unit, :degree},
        default: ~u(-3 degree),
        min: ~u(-30 degree),
        max: ~u(30 degree),
        doc: "The lean the balance controller holds, negative leaning back"
      )

      # Found on the robot rather than guessed, and paired with
      # `derivative_gain` — what matters is the ratio. The sweeps behind both are
      # in `mix help bb_nsk.add_balance`.
      param(:proportional_gain,
        type: :float,
        default: 180.0,
        min: 0.0,
        max: 250.0,
        doc: "Wheel velocity per radian of lean error, in 1/s"
      )

      # A sharp optimum, not a plateau. Above 4.0 the derivative term amplifies
      # gyro noise into the command and the wheels clip.
      param(:derivative_gain,
        type: :float,
        default: 4.0,
        min: 0.0,
        max: 20.0,
        doc: "Wheel velocity per radian per second of lean rate"
      )

      # More than a bias corrector: the commanded velocity is the only estimate
      # of speed this hardware can produce, so this is the only velocity feedback
      # in the system. Without it the robot rocks as it accelerates away.
      param(:trim_gain,
        type: :float,
        default: 0.01,
        min: 0.0,
        max: 1.0,
        doc: "How fast the setpoint chases away a persistent wheel command. Slow on purpose"
      )

      param(:trim_limit,
        type: {:unit, :degree},
        default: ~u(5 degree),
        min: ~u(0 degree),
        max: ~u(15 degree),
        doc: "How far the trim may wander before it is telling you something else is wrong"
      )

      param(:fall_angle,
        type: {:unit, :degree},
        default: ~u(30 degree),
        min: ~u(5 degree),
        max: ~u(80 degree),
        doc: "Lean error past which it gives up and waits to be stood back up"
      )

      # Tight on purpose. Any looser and the robot takes over while still moving
      # in the operator's hand, and then spends its life answering that
      # transient rather than balancing.
      param(:catch_angle,
        type: {:unit, :degree},
        default: ~u(2 degree),
        min: ~u(1 degree),
        max: ~u(30 degree),
        doc: "Lean error within which it will take over again"
      )

      param(:catch_rate,
        type: {:unit, :degree_per_second},
        default: ~u(4 degree_per_second),
        min: ~u(1 degree_per_second),
        max: ~u(200 degree_per_second),
        doc: "How still it must be held before taking over, so it can't grab mid-air"
      )
      """
    end

    defp drive_params do
      """
      # Parameter names are unique across *every* group, not just within one, so
      # these cannot be `:limit` and `:slew` — `:yaw` already has a `:limit`.
      param(:authority,
        type: {:unit, :degree},
        default: ~u(2 degree),
        min: ~u(0 degree),
        max: ~u(12 degree),
        doc: "Lean a full throttle may spend. Bounds acceleration, not speed"
      )

      param(:ramp,
        type: {:unit, :degree_per_second},
        default: ~u(8 degree_per_second),
        min: ~u(1 degree_per_second),
        max: ~u(90 degree_per_second),
        doc: "How fast the drive lean may change, so a thumb slammed over ramps rather than steps"
      )

      # Four times `ramp`: slow to wind on so a thumb slammed over does not lurch,
      # fast to unwind so letting go stops the robot promptly. If letting go
      # still feels slow, this is the knob.
      param(:release,
        type: {:unit, :degree_per_second},
        default: ~u(32 degree_per_second),
        min: ~u(1 degree_per_second),
        max: ~u(180 degree_per_second),
        doc: "How fast the drive lean returns towards zero, which is how quickly letting go stops"
      )
      """
    end

    defp yaw_params do
      """
      # Holds a heading, so a wheel finding more grip than the other doesn't
      # quietly turn the robot.
      #
      # **Both signs are confirmed on hardware**, and separately: a loop with
      # both inverted behaves exactly like one with both right, and no
      # closed-loop test can tell them apart.
      param(:gain,
        type: :float,
        default: 16.0,
        min: 0.0,
        max: 50.0,
        doc: "Differential wheel velocity per radian of heading error, in 1/s"
      )

      # Never swept — part of a tested configuration rather than a tested value.
      param(:damping,
        type: :float,
        default: 0.5,
        min: 0.0,
        max: 20.0,
        doc: "Differential wheel velocity per radian per second of yaw rate"
      )

      # Velocity spent turning is velocity unavailable for staying upright, and
      # straightening up is not worth falling over for.
      param(:limit,
        type: :float,
        default: 3.0,
        min: 0.0,
        max: 15.0,
        doc: "How much wheel velocity the heading may spend, in rad/s"
      )

      # No magnetometer, so the heading drifts and the held heading must follow
      # it. The trade: a disturbance is corrected only to the extent it happens
      # faster than this. Short is drift-tolerant and forgetful, long is patient
      # and slowly turns.
      param(:tau,
        type: :float,
        default: 10.0,
        min: 0.5,
        max: 120.0,
        doc: "Seconds for the held heading to follow the measured one"
      )
      """
    end
  end
else
  defmodule Mix.Tasks.BbNsk.AddBalance do
    @shortdoc "Adds the balance loop, its states and its commands"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("The bb_nsk.add_balance task requires igniter.")
      exit({:shutdown, 1})
    end
  end
end
