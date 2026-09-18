# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Sensor.Heading do
  @moduledoc """
  Reports which way the body is pointing, as the `:ground` joint's rotation.

  The robot balances well enough to stay where it is put, but nothing stops it
  twisting: one wheel finding more grip than the other, a slope, a nudge. This
  measures that so the balance controller can drive the wheels differentially and
  take it back out.

  ## Where the angle comes from

  The gyroscope's reading is a rate in the chip's frame. Taken through the static
  rotation from `imu_link` to `base_link` — read from the topology rather than
  written down here — its component about the body's +Z is the yaw rate, and
  integrating that is the heading.

  Strictly the rate about the *world's* vertical is `wz * cos(pitch)` plus a term
  in `wx`, and this is the small-pitch approximation of it. At the three degrees
  a balancing robot actually holds, `cos(pitch)` is 0.9986, so the approximation
  costs less than the gyro's own noise. It is the same trade
  `BB.NSK.Sensor.Lean` makes about roll, for the same reason.

  ## It drifts, and that is designed for rather than fixed

  There is no magnetometer, so rotation about gravity is unobservable and nothing
  corrects the integral. The chip's bias runs at about 0.33 degrees a second,
  which is 20 degrees a minute — so this is **not** a compass and must not be
  treated as one.

  What makes that survivable is that the controller holds a *recent* heading
  rather than an absolute one: its setpoint leaks towards whatever this reports,
  so a fast twist is corrected and a slow drift is followed and ignored. That is
  what disturbance rejection needs, and it is the only thing this sensor can
  honestly support. Driving in a straight line over a long run would need a
  heading that doesn't drift, and this is not one.

  Wrapped to `(-pi, pi]` so it stays a heading rather than growing without bound
  over a seven minute stand. Use `difference/2` to compare two of them — plain
  subtraction is wrong across the wrap.

  ## What it asserts that it doesn't know

  `:ground` is a `:planar` joint, so its configuration is a whole
  `BB.Math.Transform2D` — `x`, `y` and `theta` together. Only `theta` is
  measured. The other two are published as zero, which is what the joint already
  read before this existed, and they remain unobservable without encoders. So
  forward kinematics gets a real heading and a position that is still a
  placeholder, and anything reasoning about where the robot *is* rather than
  which way it faces is reading a number nobody measured.
  """

  use BB.Sensor,
    options_schema: [
      imu_link: [
        type: :atom,
        default: :imu_link,
        doc: "The link the gyroscope reports in, whose pose gives the static rotation"
      ],
      body_link: [
        type: :atom,
        default: :base_link,
        doc: "The link whose heading is being measured"
      ],
      imu_sensor: [
        type: :atom,
        default: :imu,
        doc: "The IMU sensor's name, as declared on `imu_link`"
      ],
      orientation_estimator: [
        type: :atom,
        default: :orientation,
        doc: "The name of the orientation estimator nested in that sensor"
      ]
    ]

  alias BB.Math.{Quaternion, Transform2D, Vec3}
  alias BB.Message.Geometry.Twist2D
  alias BB.Message.Sensor.Imu
  alias BB.NSK.Sensor.Lean

  @pi :math.pi()
  @two_pi 2 * :math.pi()

  @doc """
  The yaw rate in radians per second for a gyroscope reading, positive turning to
  the robot's left.

  `body_from_imu` rotates a rate in the chip's frame into the body's, after which
  yaw is the component about +Z — the same axis the right hand rule gives for a
  robot whose +X is forwards and +Y is to its left.
  """
  @spec yaw_rate(Vec3.t(), Quaternion.t()) :: float
  def yaw_rate(angular_velocity, body_from_imu) do
    body_from_imu
    |> Quaternion.rotate_vector(angular_velocity)
    |> Vec3.z()
  end

  @doc """
  The heading after integrating `rate` for `dt` seconds, wrapped.

  Rectangular integration, because the alternative is holding a previous rate to
  trapezoid against and at 100 Hz the difference is far below the drift that
  dominates this anyway.
  """
  @spec integrate(float, float, float) :: float
  def integrate(heading, rate, dt) when dt > 0.0, do: wrap(heading + rate * dt)
  def integrate(heading, _rate, _dt), do: heading

  @doc """
  The signed shortest angle from `b` to `a`, in radians.

  Both arguments are wrapped headings, so subtracting them directly is wrong by a
  full turn whenever they straddle the wrap. Positive means `a` is to the left of
  `b`.

      iex> import BB.NSK.Sensor.Heading
      iex> Float.round(difference(3.0, -3.0), 6)
      -0.283185
  """
  @spec difference(float, float) :: float
  def difference(a, b), do: wrap(a - b)

  @doc """
  Bring an angle into `(-pi, pi]`.
  """
  @spec wrap(float) :: float
  def wrap(angle) do
    case :math.fmod(angle, @two_pi) do
      wrapped when wrapped > @pi -> wrapped - @two_pi
      wrapped when wrapped <= -@pi -> wrapped + @two_pi
      wrapped -> wrapped
    end
  end

  @impl BB.Sensor
  def init(opts) do
    %{robot: robot, path: path} = Keyword.fetch!(opts, :bb)

    # Subscribing to the estimator's path rather than the chip's, for the same
    # reason `BB.NSK.Sensor.Lean` does: both publish `Imu` messages and only the
    # path tells them apart. The gyroscope reading is identical in each, so this
    # is about taking one of them rather than both.
    {:ok, link_path} = BB.Robot.path_to(robot.robot(), Keyword.fetch!(opts, :imu_link))

    orientation_path =
      [:sensor | link_path] ++
        [Keyword.fetch!(opts, :imu_sensor), Keyword.fetch!(opts, :orientation_estimator)]

    BB.PubSub.subscribe(robot, orientation_path, message_types: [Imu])

    {:ok,
     %{
       robot: robot,
       path: path,
       body_from_imu:
         Lean.body_from_imu(
           robot,
           Keyword.fetch!(opts, :body_link),
           Keyword.fetch!(opts, :imu_link)
         ),
       heading: 0.0,
       last: nil
     }}
  end

  @impl BB.Sensor
  def handle_info({:bb, _path, %BB.Message{payload: %Imu{} = imu} = message}, state) do
    rate = yaw_rate(imu.angular_velocity, state.body_from_imu)
    state = advance(state, rate, message.monotonic_time)

    BB.Sensor.publish_joint_state(state.robot, state.path,
      positions: [Transform2D.new(0.0, 0.0, state.heading)],
      velocities: [%Twist2D{vx: 0.0, vy: 0.0, omega: rate}]
    )

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The first sample has no predecessor to measure an interval against, and a
  # stale one would integrate a huge step.
  defp advance(%{last: nil} = state, _rate, now), do: %{state | last: now}

  defp advance(state, rate, now) do
    dt = (now - state.last) / 1_000_000_000

    %{state | heading: integrate(state.heading, rate, dt), last: now}
  end
end
