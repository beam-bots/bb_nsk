# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Balance.ControllerTest do
  use ExUnit.Case, async: false

  alias BB.Math.{Quaternion, Vec3}
  alias BB.Message.Sensor.Imu
  alias BB.NSK.Balance.Controller
  alias BB.NSK.Sensor.Lean
  alias BB.NSK.TestRobot
  alias BB.Robot.Runtime
  alias BB.Robot.Units

  @degree :math.pi() / 180

  describe "effort/4" do
    # Leaning forwards means driving forwards to get back underneath, so the
    # sign of the command follows the sign of the error.
    test "drives towards the way it is falling" do
      assert Controller.effort(0.1, 0.0, 8.0, 0.6) > 0
      assert Controller.effort(-0.1, 0.0, 8.0, 0.6) < 0
    end

    test "does nothing when it is upright and still" do
      assert Controller.effort(0.0, 0.0, 8.0, 0.6) == 0.0
    end

    # The derivative term opposes a lean that is already being corrected, which
    # is what stops it overshooting into the opposite fall.
    test "damps a lean that is already coming back" do
      falling = Controller.effort(0.1, 0.5, 8.0, 0.6)
      recovering = Controller.effort(0.1, -0.5, 8.0, 0.6)

      assert recovering < falling
    end
  end

  describe "twist/5" do
    # The opposite sense to `effort/4`, and deliberately: a lean is corrected by
    # driving towards it, a heading by turning out of it. Getting this backwards
    # gives a robot that turns further the more wrong it is.
    test "turns out of a heading error rather than into it" do
      assert Controller.twist(0.2, 0.0, 4.0, 0.5, 3.0) < 0
      assert Controller.twist(-0.2, 0.0, 4.0, 0.5, 3.0) > 0
    end

    test "does nothing when it is on heading and still" do
      assert Controller.twist(0.0, 0.0, 4.0, 0.5, 3.0) == 0.0
    end

    test "damps a heading that is already coming back" do
      drifting = Controller.twist(0.2, 0.3, 4.0, 0.5, 3.0)
      returning = Controller.twist(0.2, -0.3, 4.0, 0.5, 3.0)

      assert returning > drifting
    end

    # Wheel velocity spent on heading is velocity unavailable for staying
    # upright, and the balance loop already saturates. This clamp is the only
    # thing stopping a yaw correction from putting the robot on the floor.
    test "never spends more than the limit, in either direction" do
      assert Controller.twist(10.0, 0.0, 40.0, 0.5, 3.0) == -3.0
      assert Controller.twist(-10.0, 0.0, 40.0, 0.5, 3.0) == 3.0
      assert Controller.twist(0.0, 100.0, 4.0, 5.0, 3.0) == -3.0
    end

    test "is disabled by a zero gain and damping, whatever the error" do
      assert Controller.twist(2.0, 5.0, 0.0, 0.0, 3.0) == 0.0
    end
  end

  describe "learning?/3" do
    test "learns from a small persistent command, which is what a bias looks like" do
      assert Controller.learning?(0.4, 0.0, 2.0)
      assert Controller.learning?(-0.8, 0.0, 2.0)
    end

    # The measured separation: calm balancing sits under 0.8 rad/s and a shove
    # produces 4 to 18, so a ceiling of 2 lands in empty space between them.
    test "waits out a recovery, in either direction" do
      refute Controller.learning?(8.2, 0.0, 2.0)
      refute Controller.learning?(-11.6, 0.0, 2.0)
    end

    test "takes the ceiling as inclusive, so the boundary is not a special case" do
      assert Controller.learning?(2.0, 0.0, 2.0)
      refute Controller.learning?(2.01, 0.0, 2.0)
    end

    # A pilot holding the throttle produces exactly the sustained command the trim
    # reads as bias, so it would spend the drive trimming the steering away.
    test "waits while somebody is driving, however gentle the command" do
      refute Controller.learning?(0.0, 0.35, 2.0)
      refute Controller.learning?(0.1, -0.35, 2.0)
    end

    test "a zero drive lean is not driving, whichever zero it is" do
      assert Controller.learning?(0.1, 0.0, 2.0)
      assert Controller.learning?(0.1, -0.0, 2.0)
    end
  end

  describe "releasing?/2" do
    test "a turn that has just stopped is a release" do
      assert Controller.releasing?(true, 0.0)
    end

    # `BB.NSK.Drive` negates the pad's x deflection, so a centred thumb arrives
    # as `-0.0` — which is `==` to zero but does not *match* it.
    test "a negated zero deflection is a release too" do
      assert Controller.releasing?(true, -0.0)
    end

    # The distinction the whole thing rests on: a robot that was never turning
    # keeps holding the heading it has, rather than adopting the measured one
    # every sample and losing the hold entirely.
    test "not turning in the first place is not a release" do
      refute Controller.releasing?(false, 0.0)
    end

    test "a turn still being asked for is not a release, in either direction" do
      refute Controller.releasing?(true, 1.5)
      refute Controller.releasing?(true, -1.5)
    end
  end

  describe "rate/4" do
    # Slow out, fast back. Getting this the wrong way round costs exactly the
    # thing it exists for: how quickly letting go stops the robot.
    test "walks out at the slew rate" do
      assert Controller.rate(0.035, 0.0, 0.14, 0.56) == 0.14
    end

    test "comes back at the release rate" do
      assert Controller.rate(0.0, 0.035, 0.14, 0.56) == 0.56
    end

    test "behaves the same either side of zero" do
      assert Controller.rate(-0.035, 0.0, 0.14, 0.56) == 0.14
      assert Controller.rate(0.0, -0.035, 0.14, 0.56) == 0.56
    end

    # Decided per tick rather than once per command, and the case that rules out
    # comparing magnitudes: reversing to an equal and opposite throttle leaves the
    # magnitudes equal, so that rule would crawl the whole transit.
    test "a reversal is fast down to the balance point and slow away from it" do
      assert Controller.rate(-0.035, 0.035, 0.14, 0.56) == 0.56
      assert Controller.rate(-0.035, 0.001, 0.14, 0.56) == 0.56
      assert Controller.rate(-0.035, -0.017, 0.14, 0.56) == 0.14
      assert Controller.rate(-0.035, -0.030, 0.14, 0.56) == 0.14
    end

    test "holding the lean where it already is does not want the release rate" do
      assert Controller.rate(0.035, 0.035, 0.14, 0.56) == 0.14
    end
  end

  describe "trim/5" do
    # A persistent forward command means the setpoint is too far forward, so the
    # trim moves back to meet it.
    test "leans back when it is persistently driving forwards" do
      assert Controller.trim(0.0, 1.0, 0.002, 0.09, 0.01) < 0.0
    end

    test "leans forward when it is persistently driving backwards" do
      assert Controller.trim(0.0, -1.0, 0.002, 0.09, 0.01) > 0.0
    end

    test "holds still when the average command is zero" do
      assert Controller.trim(0.05, 0.0, 0.002, 0.09, 0.01) == 0.05
    end

    # Saturating means something other than a mismeasured centre of mass is
    # wrong, so it stops rather than winding somewhere absurd.
    test "clamps in both directions" do
      assert Controller.trim(0.0, 1000.0, 1.0, 0.09, 1.0) == -0.09
      assert Controller.trim(0.0, -1000.0, 1.0, 0.09, 1.0) == 0.09
    end

    # The first sample after a transition has no interval behind it.
    test "does nothing across no time" do
      assert Controller.trim(0.02, 5.0, 0.002, 0.09, 0.0) == 0.02
    end
  end

  describe "smooth/4" do
    # The command swings tens of rad/s either side of zero several times a
    # second. Integrating that rails the trim on whichever way the last swing
    # went; averaging it leaves the part that means the robot is going somewhere.
    test "cancels an oscillation and keeps the offset" do
      average =
        Enum.reduce(0..999, 0.0, fn i, acc ->
          oscillation = 20.0 * :math.sin(i * 2 * :math.pi() / 30)
          Controller.smooth(acc, 3.0 + oscillation, 0.01, 1.0)
        end)

      assert_in_delta average, 3.0, 0.6
    end

    test "converges on a steady value" do
      average = Enum.reduce(1..500, 0.0, fn _, acc -> Controller.smooth(acc, 5.0, 0.01, 1.0) end)

      assert_in_delta average, 5.0, 0.05
    end

    # The first sample after a transition has no interval behind it.
    test "does nothing across no time, or with no time constant" do
      assert Controller.smooth(1.5, 9.0, 0.0, 1.0) == 1.5
      assert Controller.smooth(1.5, 9.0, 0.01, 0.0) == 1.5
    end

    test "never overshoots when the step is longer than the time constant" do
      assert Controller.smooth(0.0, 4.0, 5.0, 1.0) == 4.0
    end
  end

  describe "catchable?/4" do
    test "takes over when held near upright and still" do
      assert Controller.catchable?(1 * @degree, 2 * @degree, 5 * @degree, 20 * @degree)
    end

    test "refuses when it is too far over" do
      refute Controller.catchable?(20 * @degree, 0.0, 5 * @degree, 20 * @degree)
    end

    # Without this it would grab while being carried, because a robot being
    # waved about passes through upright on the way.
    test "refuses while it is still moving, however upright" do
      refute Controller.catchable?(0.0, 90 * @degree, 5 * @degree, 20 * @degree)
    end
  end

  describe "period/1" do
    # Samples are {seconds_ago, lean, error, command, trim}, at the IMU's 100 Hz.
    # The phase offset keeps the wave off exact zeros, which are neither positive
    # nor negative and so aren't crossings.
    defp wobble(period, seconds) do
      Enum.map(0..round(seconds / 0.01), fn i ->
        t = i * 0.01

        {t, 0.0, :math.sin(2 * :math.pi() * t / period + 0.3), 0.0, 0.0}
      end)
    end

    test "measures a steady oscillation" do
      assert_in_delta Controller.period(wobble(0.2, 2.0)), 0.2, 0.02
      assert_in_delta Controller.period(wobble(0.5, 4.0)), 0.5, 0.02
    end

    # Taken from the robot: a wobble entirely below zero, because the setpoint
    # was wrong and it was leaning two degrees behind it the whole time. Counting
    # zero crossings found none of these and reported twice the real period.
    test "measures a wobble that never changes sign" do
      biased = Enum.map(wobble(0.2, 2.0), fn {t, l, e, c, m} -> {t, l, e * 0.02 - 0.04, c, m} end)

      assert Enum.all?(biased, fn {_, _, error, _, _} -> error < 0 end)
      assert_in_delta Controller.period(biased), 0.2, 0.02
    end

    # Falling one way and staying there has no period, and reporting one would
    # send a tuning session after a number that means nothing.
    test "reports nothing when the error never changes sign" do
      refute Controller.period([{0.0, 0.0, 0.1, 0.0, 0.0}, {0.1, 0.0, 0.2, 0.0, 0.0}])
    end

    test "reports nothing for a single crossing" do
      refute Controller.period([{0.0, 0.0, -0.1, 0.0, 0.0}, {0.1, 0.0, 0.2, 0.0, 0.0}])
    end

    # A four second trace covers wobbling, falling and being picked up, so a few
    # long gaps sit among the real intervals. Averaging them answered 0.299 on
    # the robot for a wobble that was 0.13.
    test "is not dragged out by a few long excursions" do
      steady = wobble(0.2, 2.0)
      drifted = Enum.map(wobble(1.4, 4.0), fn {t, l, e, c, m} -> {t + 2.0, l, e, c, m} end)

      assert_in_delta Controller.period(steady ++ drifted), 0.2, 0.04
    end
  end

  describe "report/2" do
    defp samples(overrides) do
      error = Keyword.get(overrides, :error, 0.0)
      command = Keyword.get(overrides, :command, 0.0)
      trim = Keyword.get(overrides, :trim, 0.0)

      Enum.map(0..99, fn i -> {i * 0.01, 0.0, error, command, trim} end)
    end

    test "says nothing useful about nothing" do
      assert %{samples: 0, notes: ["nothing recorded"]} = Controller.report([], [])
    end

    # The failure that took a whole evening: driving steadily in one direction
    # because the setpoint is somewhere the robot cannot stand.
    test "notices a robot driving steadily in one direction" do
      %{notes: notes} = Controller.report(samples(command: -5.8, error: -0.04), [])

      assert Enum.any?(notes, &(&1 =~ "driving steadily backwards"))
      assert Enum.any?(notes, &(&1 =~ "sitting -2.29 degrees off the setpoint"))
    end

    # A trim on its clamp is a stuck integrator, not a working one.
    test "notices a trim on its clamp" do
      %{notes: notes} = Controller.report(samples(trim: 5 * @degree, command: -3.0), [])

      assert Enum.any?(notes, &(&1 =~ "on its clamp"))
    end

    test "notices a command that has run out of motor" do
      %{notes: notes} = Controller.report(samples(command: -35.0), [])

      assert Enum.any?(notes, &(&1 =~ "saturating"))
    end

    test "keeps quiet about a loop that is behaving" do
      %{notes: notes} = Controller.report(samples([]), [])

      refute Enum.any?(notes, &(&1 =~ "driving steadily"))
      refute Enum.any?(notes, &(&1 =~ "clamp"))
      refute Enum.any?(notes, &(&1 =~ "saturating"))
    end
  end

  describe "the state machine, end to end" do
    setup do
      # A robot of this test's own, torn down with it. Sharing one across the
      # suite meant a test that armed it or left a drive command live failed a
      # different test in a later file.
      start_supervised!({TestRobot, []})

      {:ok, link_path} = BB.Robot.path_to(TestRobot.robot(), :imu_link)

      {:ok, setpoint} = BB.Parameter.get(TestRobot, [:balance, :setpoint])

      %{
        path: [:sensor | link_path] ++ [:imu, :orientation],
        rotation: Lean.body_from_imu(TestRobot, :base_link, :imu_link),
        # Leans are expressed relative to this, so moving the setpoint doesn't
        # silently turn "held at the balance point" into "six degrees off it".
        setpoint: Units.extract_float(setpoint)
      }
    end

    # Synthesise the orientation a given lean would produce, so the real sensor
    # and the real controller run against it.
    defp lean(%{path: path, rotation: rotation}, degrees, rate_degrees) do
      orientation =
        Quaternion.multiply(
          Quaternion.from_axis_angle(Vec3.new(0.0, 1.0, 0.0), degrees * @degree),
          rotation
        )

      gyro =
        Quaternion.rotate_vector(
          Quaternion.inverse(rotation),
          Vec3.new(0.0, rate_degrees * @degree, 0.0)
        )

      {:ok, message} =
        Imu.new(:imu,
          orientation: orientation,
          angular_velocity: gyro,
          linear_acceleration: Vec3.new(0.0, 0.0, 0.0)
        )

      BB.PubSub.publish(TestRobot, path, message)
      Process.sleep(30)

      Runtime.state(TestRobot)
    end

    # Arming used to land in `:idle` whatever attitude the robot was in, so a
    # robot armed on its side sat there calling itself idle — and showing the
    # same green on the NeoPixels as one standing ready to go.
    test "arming a robot on its side lands straight in fallen", context do
      lean(context, 50.0, 0.0)

      {:ok, command} = TestRobot.arm()
      {:ok, :armed, _opts} = BB.Command.await(command)

      assert Runtime.state(TestRobot) == :fallen
    end

    # Decided by the command rather than a sample later, so there is no window
    # in which the robot is armed and calling itself something it isn't.
    test "arming a robot held upright and still lands straight in balancing", context do
      lean(context, context.setpoint, 0.0)

      {:ok, command} = TestRobot.arm()
      {:ok, :armed, _opts} = BB.Command.await(command)

      assert Runtime.state(TestRobot) == :balancing
    end

    test "takes over, gives up, and can be disarmed from either", context do
      {:ok, command} = TestRobot.arm()
      {:ok, :armed, _opts} = BB.Command.await(command)

      assert lean(context, context.setpoint, 0.0) == :balancing
      assert lean(context, context.setpoint + 45, 0.0) == :fallen

      # Being carried near upright is not an invitation to take over.
      assert lean(context, context.setpoint, 90.0) == :fallen
      assert lean(context, context.setpoint + 1, 2.0) == :balancing

      {:ok, command} = TestRobot.disarm()
      BB.Command.await(command)

      assert BB.Safety.state(TestRobot) == :disarmed
    end
  end
end
