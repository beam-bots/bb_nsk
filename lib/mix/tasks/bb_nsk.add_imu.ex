# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbNsk.AddImu do
    @shortdoc "Adds the Balance Bot's IMU, its filter and the two derived sensors"
    @moduledoc """
    #{@shortdoc}

    Mounts the BMI323 where it actually sits on the board, nests a Mahony filter
    in it to fuse an orientation, and adds the two sensors that turn that
    orientation into joint configurations the rest of the robot can use:
    `BB.NSK.Sensor.Lean` on `:lean` and `BB.NSK.Sensor.Heading` on `:ground`.

    After this `BB.Robot.State` carries a lean that means something, which is
    what `bb_nsk.add_balance` closes its loop around.

    ## Why the mounting is two joints

    The chip publishes in its own axes and a `sensor` has no origin of its own —
    the link it hangs off is its frame — so the mounting is a pair of links, and
    everything downstream gets the transform from the kinematics rather than
    hard-coding an axis swap.

    Where it sits and how it is turned are separate joints because
    `BB.Math.Transform.from_origin/1` composes the rotation before the
    translation, so one origin carrying both would place the chip at its own
    offset seen through its own quarter turn — 29.5mm forward of the wheel axis
    instead of 29.5mm above it.

    The rotation itself was read off the gravity vector in two attitudes rather
    than off the silkscreen: on its back the whole g lands on the chip's +Z, and
    on its wheels it lands on -Y.

    ## Why Mahony rather than Madgwick

    Both fuse the same two signals, and both have one gain saying how hard the
    accelerometer may pull the estimate around. That gain has to be small here:
    an accelerometer cannot tell leaning from accelerating, and this robot
    accelerates hardest exactly when it most needs the lean to be right. At
    Madgwick's default of 0.1 the robot balanced for one to two seconds no
    matter what else was tuned.

    But a small gain also washes gyroscope bias out slowly, and bias moves with
    temperature and time since power-on — which reads as a balance point that
    wanders between attempts. Madgwick has no answer to that; its only dial is
    the one already needed low. Mahony estimates the bias separately with `ki`,
    so the two jobs stop fighting over one number.

    ## Example

    ```bash
    mix bb_nsk.add_imu
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
          |> BB.Igniter.add_param_group(robot_module, [:sampling], sampling_params())
          |> BB.Igniter.add_param_group(robot_module, [:ahrs], ahrs_params())
          |> NSK.append_to_link(robot_module, :base_link, imu_mount(), {
            :joint,
            :imu_mount_joint
          })
          |> add_derived_sensors(robot_module)

        {igniter, false} ->
          Igniter.add_warning(igniter, """
          bb_nsk.add_imu found no `:base_link` in #{inspect(robot_module)}'s
          topology, so it added nothing. Run `mix bb_nsk.install` first.
          """)
      end
    end

    # Both sensors report a *joint's* configuration rather than anything about a
    # link, so they belong in the joint's body: the lean is exactly what the
    # `:lean` joint is doing, derived from an IMU two links below it.
    defp add_derived_sensors(igniter, robot_module) do
      igniter
      |> NSK.append_to_joint(robot_module, :lean, lean_sensor(), {:sensor, :lean_angle})
      |> NSK.append_to_joint(robot_module, :ground, heading_sensor(), {:sensor, :heading})
    end

    defp lean_sensor do
      """
      # No actuator, but the lean is observable: the IMU hangs off a link below
      # this joint, and what it reports about gravity is exactly this joint's
      # configuration.
      sensor(:lean_angle, BB.NSK.Sensor.Lean)
      """
    end

    defp heading_sensor do
      """
      # The heading is observable even though the position isn't: the gyro
      # measures yaw rate directly, and integrating it is a real angle where dead
      # reckoning `x` and `y` from wheel commands would be a fiction. So this
      # joint's `theta` means something and its translation still doesn't.
      sensor(:heading, BB.NSK.Sensor.Heading)
      """
    end

    defp sampling_params do
      """
      # This is the balance loop's rate. The robot falls with a 68ms time
      # constant, so samples per fall matter more than they sound — see
      # `mix help bb_nsk.add_imu`.
      #
      # The chip's ODR is 200 Hz, so going above that repeats samples unless the
      # ODR below is raised with it.
      param(:publish_rate,
        type: {:unit, :hertz},
        default: ~u(200 hertz),
        min: ~u(10 hertz),
        max: ~u(400 hertz),
        doc: "How often the IMU publishes, which is the rate the balance loop runs at"
      )
      """
    end

    defp ahrs_params do
      """
      # The filter sits *inside* the control loop, so its lag is part of the
      # plant the balance gains are tuned against — changing one invalidates the
      # tuning of the other.
      param(:kp,
        type: :float,
        default: 0.4,
        min: 0.0,
        max: 5.0,
        doc: "How hard the accelerometer may pull the estimate. Small: it can't tell lean from acceleration"
      )

      # Defaults to zero in the library, so it has to be set.
      param(:ki,
        type: :float,
        default: 0.005,
        min: 0.0,
        max: 0.5,
        doc: "Gyroscope bias estimation. Zero is proportional-only, which drifts"
      )
      """
    end

    defp imu_mount do
      """
      # The chip publishes in its own axes and a `sensor` has no origin — the
      # link it hangs off is its frame — so the mounting is links of its own and
      # everything downstream gets the transform from the kinematics.
      #
      # **Two joints rather than one origin carrying both**, because
      # `BB.Math.Transform.from_origin/1` composes the rotation before the
      # translation: one origin with both would put the chip 29.5mm *forward* of
      # the wheel axis instead of above it.
      joint :imu_mount_joint do
        type(:fixed)
        origin(x: ~u(-4.9 millimeter), z: ~u(29.5 millimeter))

        link :imu_mount do
          joint :imu_joint do
            type(:fixed)
            origin(pitch: ~u(90 degree), yaw: ~u(-90 degree))

            link :imu_link do
              # The driver stops rather than declining when the chip isn't
              # there, which on a host would take the supervision tree with it.
              if Mix.target() != :host do
                sensor :imu,
                       {BB.Sensor.BMI323,
                        bus: "i2c-0",
                        address: 0x68,
                        mode: :polling,
                        accelerometer_range: 4,
                        accelerometer_odr: 200,
                        gyroscope_range: 500,
                        gyroscope_odr: 200,
                        publish_rate: param([:sampling, :publish_rate])} do
                  # No magnetometer, so the chip publishes an identity
                  # orientation and this fuses a real one.
                  estimator(
                    :orientation,
                    {BB.Estimator.Ahrs.Mahony, kp: param([:ahrs, :kp]), ki: param([:ahrs, :ki])}
                  )
                end
              end
            end
          end
        end
      end
      """
    end
  end
else
  defmodule Mix.Tasks.BbNsk.AddImu do
    @shortdoc "Adds the Balance Bot's IMU, its filter and the two derived sensors"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("The bb_nsk.add_imu task requires igniter.")
      exit({:shutdown, 1})
    end
  end
end
