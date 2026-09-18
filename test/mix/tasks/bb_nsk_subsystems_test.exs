# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.BbNsk.SubsystemsTest do
  use BB.NSK.TaskCase, async: true

  describe "bb_nsk.add_wheels" do
    setup do
      %{
        robot:
          installed_project() |> Igniter.compose_task("bb_nsk.add_wheels", []) |> robot_source()
      }
    end

    test "hangs both wheels off base_link", %{robot: robot} do
      assert robot =~ "joint :left_wheel_joint"
      assert robot =~ "joint :right_wheel_joint"
      assert robot =~ "BB.NSK.Wheel"
    end

    # Which way round the PWM channels go is confirmed against the hardware by
    # driving each wheel and watching. Left is the robot's left, and this has
    # been got wrong three times — the pairing is the thing worth pinning down.
    test "pairs each wheel with the channels and enable pin it is actually wired to", %{
      robot: robot
    } do
      assert robot =~ ~r/:left_wheel,.*forward_pwm: 3,.*reverse_pwm: 2,.*enable_pin: "PE6"/s
      assert robot =~ ~r/:right_wheel,.*forward_pwm: 5,.*reverse_pwm: 4,.*enable_pin: "PE11"/s
    end

    test "adds the deadband parameter the compensation reads", %{robot: robot} do
      assert robot =~ "group :motor"
      assert robot =~ "param(:deadband"
      assert robot =~ "deadband: param([:motor, :deadband])"
    end

    test "says so rather than succeeding quietly against a robot with no base_link" do
      igniter =
        nerves_project(
          files: %{
            "lib/my_bot/robot.ex" => """
            defmodule MyBot.Robot do
              use BB

              topology do
                link :chassis do
                end
              end
            end
            """
          }
        )
        |> Igniter.compose_task("bb_nsk.add_wheels", [])

      assert Enum.any?(igniter.warnings, &(&1 =~ "bb_nsk.install"))
    end
  end

  describe "bb_nsk.add_imu" do
    setup do
      %{
        robot: installed_project() |> Igniter.compose_task("bb_nsk.add_imu", []) |> robot_source()
      }
    end

    # Where it sits and how it is turned are separate joints because
    # `Transform.from_origin/1` composes the rotation before the translation, so
    # one origin carrying both would put the chip 29.5mm *forward* of the wheel
    # axis rather than above it.
    test "mounts the chip as two joints rather than one origin", %{robot: robot} do
      assert robot =~ "joint :imu_mount_joint"
      assert robot =~ "joint :imu_joint"
      assert robot =~ ~r/origin\(pitch: ~u\(90 degree\), yaw: ~u\(-90 degree\)\)/
    end

    # The driver stops rather than declining when the chip isn't there, which on
    # the host would take the robot's supervision tree with it.
    test "declares the sensor only where the hardware is", %{robot: robot} do
      assert robot =~ "if Mix.target() != :host do"
      assert robot =~ "BB.Sensor.BMI323"
    end

    # Mahony rather than Madgwick, for `ki`: a gain small enough not to mistake
    # acceleration for lean also washes gyro bias out too slowly, and Madgwick
    # has only the one dial.
    test "nests a Mahony filter to fuse an orientation", %{robot: robot} do
      assert robot =~ "BB.Estimator.Ahrs.Mahony"
      assert robot =~ "ki: param([:ahrs, :ki])"
    end

    # Both report a joint's own configuration, so they belong in the joint's
    # body rather than on a link.
    test "puts the derived sensors on the joints they measure", %{robot: robot} do
      assert robot =~ ~r/joint :lean do.*sensor\(:lean_angle, BB\.NSK\.Sensor\.Lean\)/s
      assert robot =~ ~r/joint :ground do.*sensor\(:heading, BB\.NSK\.Sensor\.Heading\)/s
    end
  end

  describe "bb_nsk.add_balance" do
    setup do
      igniter =
        installed_project()
        |> Igniter.compose_task("bb_nsk.add_imu", [])
        |> apply_igniter!()
        |> Igniter.compose_task("bb_nsk.add_balance", [])

      %{igniter: igniter, robot: robot_source(igniter)}
    end

    test "adds the loop and the states it drives", %{robot: robot} do
      assert robot =~ "BB.NSK.Balance.Controller"
      assert robot =~ "state(:balancing"
      assert robot =~ "state(:fallen"
    end

    # `bb.install` writes an `arm` that always lands in `:idle`, so a robot armed
    # while already on its side would sit there calling itself idle.
    test "replaces arm with one that reads the robot's attitude", %{robot: robot} do
      assert robot =~ "BB.NSK.Command.Arm"
      refute robot =~ "handler(BB.Command.Arm)"
      assert robot =~ "arm(true)"
    end

    # Disarming has to be reachable from every state the robot can get stuck in,
    # or a robot that has fallen over can't be switched off.
    test "widens disarm to reach every state", %{robot: robot} do
      assert robot =~ ~r/command :disarm do.*allowed_states\(\[:idle, :balancing, :fallen\]\)/s
    end

    test "wires every gain to a parameter", %{robot: robot} do
      for group <- ["group :balance", "group :yaw", "group :drive"] do
        assert robot =~ group
      end

      assert robot =~ "proportional_gain: param([:balance, :proportional_gain])"
    end

    # A balance loop with nothing to balance against is a robot that arms and
    # then silently never stands up.
    test "warns when there is no lean sensor to close around" do
      igniter = installed_project() |> Igniter.compose_task("bb_nsk.add_balance", [])

      assert Enum.any?(igniter.warnings, &(&1 =~ "bb_nsk.add_imu"))
    end
  end

  describe "bb_nsk.cheat" do
    # The tasks `cheat` composes that write to the robot module.
    #
    # `add_wifi` is not one of them — it only touches config and the supervision
    # tree — and `add_web` needs `phx_install` on the code path, which a synthetic
    # test project has no way to carry. Both are covered end to end instead.
    @robot_tasks [
      "bb_nsk.add_wheels",
      "bb_nsk.add_imu",
      "bb_nsk.add_balance",
      "bb_nsk.add_leds",
      "bb_nsk.add_environment_sensor",
      "bb_nsk.add_display"
    ]

    # The whole point of `cheat` is that it is a plain composition. If it ever
    # diverges from running the tasks by hand, one of the two is lying about
    # what the workshop builds.
    test "reaches the same robot as running every task in turn" do
      {last, earlier} = List.pop_at(@robot_tasks, -1)

      # Applied between each, the way a person running them one at a time gets —
      # but not after the last, or there is no pending change left to read.
      stepwise =
        earlier
        |> Enum.reduce(installed_project(), fn task, igniter ->
          igniter |> Igniter.compose_task(task, []) |> apply_igniter!()
        end)
        |> Igniter.compose_task(last, [])
        |> robot_source()

      cheated =
        @robot_tasks
        |> Enum.reduce(installed_project(), &Igniter.compose_task(&2, &1, []))
        |> robot_source()

      assert cheated == stepwise
    end

    # Someone who worked through the first few tasks by hand and then ran out of
    # time gets the rest, and keeps what they did to the ones already run.
    test "is safe over a project that is already half built" do
      half_built =
        installed_project()
        |> Igniter.compose_task("bb_nsk.add_wheels", [])
        |> apply_igniter!()

      once =
        Enum.reduce(@robot_tasks, half_built, &Igniter.compose_task(&2, &1, []))

      # The wheels the first pass added are still there and still singular —
      # `cheat` filled in the IMU and the balance loop around them rather than
      # adding a second pair.
      robot = robot_source(once)
      assert robot =~ "joint :left_wheel_joint"
      assert robot =~ "BB.NSK.Balance.Controller"
      assert length(String.split(robot, "joint :left_wheel_joint")) == 2

      # And a third pass leaves the file alone entirely rather than rewriting it
      # to the same thing.
      applied = apply_igniter!(once)

      Enum.reduce(@robot_tasks, applied, &Igniter.compose_task(&2, &1, []))
      |> assert_unchanged("lib/my_bot/robot.ex")
    end
  end
end
