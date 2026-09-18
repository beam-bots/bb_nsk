# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.WheelTest do
  use ExUnit.Case, async: true

  alias BB.Message.Actuator.Command
  alias BB.NSK.{PWM, Wheel}

  describe "drive_ratio/2" do
    test "asks for duty in proportion to the speed wanted" do
      assert Wheel.drive_ratio(10.0, 20.0) == 0.5
      assert Wheel.drive_ratio(20.0, 20.0) == 1.0
      assert Wheel.drive_ratio(0.0, 20.0) == 0.0
    end

    test "keeps the sign, since that is the direction" do
      assert Wheel.drive_ratio(-10.0, 20.0) == -0.5
      assert Wheel.drive_ratio(-20.0, 20.0) == -1.0
    end

    # Asking for more than the wheel can do should give everything it has, not
    # a duty cycle over 1.0 that the kernel would reject.
    test "clamps rather than exceeding full duty" do
      assert Wheel.drive_ratio(1000.0, 20.0) == 1.0
      assert Wheel.drive_ratio(-1000.0, 20.0) == -1.0
    end

    # Writing a duty cycle costs over a millisecond, and `BB.NSK.PWM` only skips the
    # write when the value is unchanged — which a raw control output never is.
    test "rounds to steps, so a command that has barely moved doesn't cost a write" do
      assert Wheel.drive_ratio(10.0, 20.0) == Wheel.drive_ratio(10.0001, 20.0)
      refute Wheel.drive_ratio(10.0, 20.0) == Wheel.drive_ratio(10.1, 20.0)
    end

    test "refuses to divide by a top speed of zero" do
      assert Wheel.drive_ratio(10.0, 0.0) == 0.0
      assert Wheel.drive_ratio(10.0, -5.0) == 0.0
    end
  end

  describe "compensate/2" do
    # The motor needs 40% duty before it turns at all, so without this the
    # bottom 40% of the controller's range asks for nothing and the loop is dead
    # exactly where it spends its time.
    test "lifts the smallest command clear of the deadband" do
      assert Wheel.compensate(0.002, 0.4) > 0.4
      assert Wheel.compensate(-0.002, 0.4) < -0.4
    end

    test "leaves full duty meaning full duty" do
      assert Wheel.compensate(1.0, 0.4) == 1.0
      assert Wheel.compensate(-1.0, 0.4) == -1.0
    end

    # Zero has to stay zero, or a robot asked to stop would creep.
    test "passes zero through" do
      assert Wheel.compensate(0.0, 0.4) == 0.0
    end

    test "changes nothing when there is no deadband to skip" do
      assert Wheel.compensate(0.25, 0.0) == 0.25
      assert Wheel.compensate(-0.25, 0.0) == -0.25
    end

    test "stays monotonic, so more command is always more duty" do
      ratios = [0.1, 0.2, 0.3, 0.5, 0.8, 1.0]
      compensated = Enum.map(ratios, &Wheel.compensate(&1, 0.4))

      assert compensated == Enum.sort(compensated)
    end
  end

  describe "watchdog/2" do
    # A duty cycle written to the kernel never expires, so a wheel driving when
    # its controller stops talking drives until something intervenes. This is
    # what a robot lying on its side with its wheels at full speed looks like.
    # Channels already at zero duty, so `PWM.off/1` takes its "nothing changed"
    # path and never reaches for the file descriptor it hasn't got.
    defp driving(commanded_at) do
      %{
        mode: :forward,
        commanded_at: commanded_at,
        command_timeout: 250,
        forward: %PWM{duty: 0},
        reverse: %PWM{duty: 0}
      }
    end

    test "leaves a wheel alone while commands are arriving" do
      assert Wheel.watchdog(driving(1_000), 1_100).mode == :forward
      assert Wheel.watchdog(driving(1_000), 1_249).mode == :forward
    end

    # Coast rather than brake: the case this exists for is nobody knowing what
    # is going on, and going passive is the honest response to that.
    test "coasts a wheel whose controller has gone quiet" do
      assert Wheel.watchdog(driving(1_000), 1_250).mode == :coast
      assert Wheel.watchdog(driving(1_000), 5_000).mode == :coast
    end

    test "has nothing to do for a wheel that was never commanded" do
      state = %{mode: :coast, commanded_at: nil, command_timeout: 250}

      assert Wheel.watchdog(state, 10_000) == state
    end

    # Already where the watchdog would put them, and braking is a deliberate
    # state that silence shouldn't undo.
    test "leaves coasting and braking wheels as they are" do
      for mode <- [:coast, :brake] do
        state = %{mode: mode, commanded_at: 1_000, command_timeout: 250}

        assert Wheel.watchdog(state, 10_000) == state
      end
    end
  end

  describe "command_payloads/1" do
    # Without an encoder this driver can't honour a position or an effort, and
    # BB refuses anything undeclared before it reaches the driver.
    test "accepts velocity, stop and hold, and nothing it cannot honour" do
      payloads = Wheel.command_payloads([])

      assert Command.Velocity in payloads
      assert Command.Stop in payloads
      refute Command.Position in payloads
      refute Command.Effort in payloads
      refute Command.Trajectory in payloads
    end

    # The bridge's brake mode resists rotation without knowing where the wheel
    # is, so `Hold` is honoured even though `Position` can't be.
    test "accepts hold, which the bridge can brake for" do
      assert Command.Hold in Wheel.command_payloads([])
    end
  end

  describe "BB.NSK.PWM" do
    test "turns a frequency into a period in nanoseconds" do
      assert PWM.period(20_000) == 50_000
      assert PWM.period(1_000) == 1_000_000
    end

    test "knows the board has no PWM when the kernel isn't offering any" do
      refute PWM.available?("nonexistent-chip")
    end
  end
end
