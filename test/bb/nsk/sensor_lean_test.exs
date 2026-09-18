# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Sensor.LeanTest do
  use ExUnit.Case, async: true

  alias BB.Math.{Quaternion, Vec3}
  alias BB.NSK.Sensor.Lean
  alias BB.NSK.TestRobot

  @degree :math.pi() / 180

  defp upright, do: Quaternion.identity()
  defp pitched(radians), do: Quaternion.from_axis_angle(Vec3.new(0.0, 1.0, 0.0), radians)

  describe "lean/2" do
    # With the chip's axes already the body's, the orientation is the lean.
    test "is zero when the body's up is the world's" do
      assert_in_delta Lean.lean(upright(), upright()), 0.0, 1.0e-9
    end

    test "follows a rotation about the body's Y, positive forwards" do
      for degrees <- [-60, -30, -5, 5, 30, 60] do
        radians = degrees * @degree

        assert_in_delta Lean.lean(pitched(radians), upright()), radians, 1.0e-9
      end
    end

    # Yaw moves the up vector not at all, which is what makes the angle usable
    # from an estimator with no magnetometer to pin its heading.
    test "ignores rotation about gravity" do
      lean = 20 * @degree
      tilt = pitched(lean)

      for degrees <- [-180, -90, 45, 170] do
        yaw = Quaternion.from_axis_angle(Vec3.new(0.0, 0.0, 1.0), degrees * @degree)

        assert_in_delta Lean.lean(Quaternion.multiply(yaw, tilt), upright()), lean, 1.0e-9
      end
    end
  end

  describe "lean/2 and roll" do
    # The bug this replaced: dividing by z alone leaves a cos(roll) in the
    # denominator, so rolling the robot inflates its apparent lean — a five
    # degree pitch reads 5.8 at thirty degrees of roll and 9.9 at sixty. On a
    # balance bot that is a coupling, not an inaccuracy: rolling motion modulates
    # the measured lean and drives the pitch loop from an axis it cannot see.
    test "reports the same lean however far the robot is rolled" do
      for pitch <- [-20, -5, 0, 5, 20], roll <- [-60, -30, 0, 30, 60] do
        orientation =
          Quaternion.multiply(
            pitched(pitch * @degree),
            Quaternion.from_axis_angle(Vec3.new(1.0, 0.0, 0.0), roll * @degree)
          )

        assert_in_delta Lean.lean(orientation, upright()) / @degree, pitch, 0.001
      end
    end

    test "a pure roll is not a lean at all" do
      for roll <- [-90, -45, 45, 90] do
        rolled = Quaternion.from_axis_angle(Vec3.new(1.0, 0.0, 0.0), roll * @degree)

        assert_in_delta Lean.lean(rolled, upright()), 0.0, 1.0e-9
      end
    end
  end

  describe "lean_rate/2" do
    test "takes the component about the body's Y" do
      assert Lean.lean_rate(Vec3.new(0.3, 1.5, -0.2), upright()) == 1.5
    end

    test "is zero when nothing is turning" do
      assert Lean.lean_rate(Vec3.new(0.0, 0.0, 0.0), upright()) == 0.0
    end
  end

  describe "against the robot's own topology" do
    setup do
      %{rotation: Lean.body_from_imu(TestRobot, :base_link, :imu_link)}
    end

    test "puts the chip's axes where the mounting says", %{rotation: rotation} do
      right = Quaternion.rotate_vector(rotation, Vec3.new(1.0, 0.0, 0.0))
      down = Quaternion.rotate_vector(rotation, Vec3.new(0.0, 1.0, 0.0))
      forward = Quaternion.rotate_vector(rotation, Vec3.new(0.0, 0.0, 1.0))

      assert_in_delta Vec3.y(right), -1.0, 1.0e-9
      assert_in_delta Vec3.z(down), -1.0, 1.0e-9
      assert_in_delta Vec3.x(forward), 1.0, 1.0e-9
    end

    # The chip's +Z is up when the robot lies on its back, and that is the
    # attitude the estimator's reference was established in, so it reports an
    # identity orientation there. A robot on its back has fallen backwards.
    test "reads a quarter turn back when it is lying down", %{rotation: rotation} do
      assert_in_delta Lean.lean(upright(), rotation), -90 * @degree, 1.0e-9
    end

    # Taken off the robot standing approximately upright, alongside a gravity
    # vector of (0.403, -9.729, 0.388).
    test "reads near zero for a measured upright orientation", %{rotation: rotation} do
      measured =
        Quaternion.new(
          0.6647878043845505,
          -0.6287967855647411,
          -0.2923228262876192,
          0.2778833259413674
        )

      assert_in_delta Lean.lean(measured, rotation) / @degree, -2.2, 0.1
    end
  end
end
