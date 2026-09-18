# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Sensor.HeadingTest do
  use ExUnit.Case, async: true

  doctest BB.NSK.Sensor.Heading

  alias BB.Math.{Quaternion, Vec3}
  alias BB.NSK.Sensor.{Heading, Lean}
  alias BB.NSK.TestRobot

  @pi :math.pi()

  defp aligned, do: Quaternion.identity()

  describe "yaw_rate/2" do
    # With the chip's axes already the body's, yaw is the reading's own Z.
    test "takes the component about the body's Z" do
      assert_in_delta Heading.yaw_rate(Vec3.new(0.0, 0.0, 1.5), aligned()), 1.5, 1.0e-9
    end

    test "is zero for a pure pitch or roll rate" do
      assert_in_delta Heading.yaw_rate(Vec3.new(2.0, 0.0, 0.0), aligned()), 0.0, 1.0e-9
      assert_in_delta Heading.yaw_rate(Vec3.new(0.0, 2.0, 0.0), aligned()), 0.0, 1.0e-9
    end

    # Against the real mounting from the topology, not a quaternion built here —
    # the composition order is easy to get wrong and getting it wrong turns a yaw
    # correction into a pitch disturbance, which a balance bot does not survive.
    #
    # The chip stands upright across the front of the body: its +Z points
    # forwards, +Y at the floor, +X to the robot's right. So the body's yaw axis
    # is the chip's -Y.
    test "follows the mounting rotation rather than the chip's own axes" do
      mounting = Lean.body_from_imu(TestRobot, :base_link, :imu_link)

      assert_in_delta Heading.yaw_rate(Vec3.new(0.0, -1.0, 0.0), mounting), 1.0, 1.0e-9
      assert_in_delta Heading.yaw_rate(Vec3.new(0.0, 1.0, 0.0), mounting), -1.0, 1.0e-9

      # Forwards and rightwards rates are pitch and roll, and must not reach yaw.
      assert_in_delta Heading.yaw_rate(Vec3.new(0.0, 0.0, 1.0), mounting), 0.0, 1.0e-9
      assert_in_delta Heading.yaw_rate(Vec3.new(1.0, 0.0, 0.0), mounting), 0.0, 1.0e-9
    end
  end

  describe "integrate/3" do
    test "accumulates rate over time" do
      assert_in_delta Heading.integrate(0.0, 1.0, 0.5), 0.5, 1.0e-9
      assert_in_delta Heading.integrate(0.5, -2.0, 0.25), 0.0, 1.0e-9
    end

    test "ignores a non-positive interval, so a repeated timestamp cannot move it" do
      assert Heading.integrate(0.3, 10.0, 0.0) == 0.3
      assert Heading.integrate(0.3, 10.0, -0.1) == 0.3
    end

    # Seven minutes of standing at the chip's own bias would otherwise leave the
    # joint holding tens of radians.
    test "stays wrapped however long it runs" do
      heading =
        Enum.reduce(1..2000, 0.0, fn _step, heading ->
          Heading.integrate(heading, 1.0, 0.01)
        end)

      assert heading > -@pi and heading <= @pi
    end
  end

  describe "wrap/1" do
    test "leaves an angle already in range alone" do
      for angle <- [-3.0, -1.0, 0.0, 1.0, 3.0] do
        assert_in_delta Heading.wrap(angle), angle, 1.0e-9
      end
    end

    test "brings a whole turn back to where it started" do
      for angle <- [-2.5, 0.0, 1.7, 3.0] do
        assert_in_delta Heading.wrap(angle + 2 * @pi), angle, 1.0e-9
        assert_in_delta Heading.wrap(angle - 2 * @pi), angle, 1.0e-9
      end
    end

    test "closes the interval at +pi and opens it at -pi" do
      assert_in_delta Heading.wrap(@pi), @pi, 1.0e-9
      assert_in_delta Heading.wrap(-@pi), @pi, 1.0e-9
    end
  end

  describe "difference/2" do
    test "is plain subtraction away from the wrap" do
      assert_in_delta Heading.difference(1.0, 0.25), 0.75, 1.0e-9
      assert_in_delta Heading.difference(0.25, 1.0), -0.75, 1.0e-9
    end

    # The case plain subtraction gets wrong by a full turn, and the reason this
    # function exists: 3.0 and -3.0 rad are 16 degrees apart, not 344. Going from
    # -3.0 to 3.0 is a right turn, so the difference is negative.
    test "takes the short way round across the wrap" do
      assert_in_delta Heading.difference(3.0, -3.0), 6.0 - 2 * @pi, 1.0e-9
      assert_in_delta Heading.difference(-3.0, 3.0), 2 * @pi - 6.0, 1.0e-9
    end

    test "is zero for equal headings and never exceeds half a turn" do
      for angle <- [-3.1, -1.0, 0.0, 2.2, 3.1] do
        assert_in_delta Heading.difference(angle, angle), 0.0, 1.0e-9
      end

      for a <- [-3.0, -1.0, 0.5, 3.0], b <- [-3.0, -1.0, 0.5, 3.0] do
        assert abs(Heading.difference(a, b)) <= @pi + 1.0e-9
      end
    end
  end
end
