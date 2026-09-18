# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Sensor.Lean do
  @moduledoc """
  Reports how far the body has fallen away from upright, as the `:lean` joint's
  configuration.

  The IMU knows which way is down and the topology knows how the chip is bolted
  to the body, but nothing joined the two: forward kinematics reported the robot
  bolt upright no matter what the accelerometer said. This closes that loop, so
  `BB.Robot.State` carries a lean that means something and anything reasoning
  about the robot's pose gets it for free.

  ## Where the angle comes from

  The fused orientation is a rotation from the chip's frame into the estimator's
  world, whose Z is up. Taking the world's up vector back through it gives up in
  the chip's frame, and the static rotation from `imu_link` to `base_link` — read
  from the topology rather than written down here — puts it in the body's. Level,
  that vector is the body's own +Z; leaning forward tips it towards -X. So the
  angle is `atan2(-x, z)`, positive forwards, which is the sense `:lean` is
  declared with.

  The rate comes from the gyroscope through the same rotation, taking the
  component about the body's Y. A balance controller wants both, and
  differentiating the angle would be a worse rate than the one the gyro
  measures directly. Strictly the pitch rate is `wy * cos(roll) - wz * sin(roll)`
  and this is the small-roll approximation of it, which for a robot that is
  supposed to stay upright is the case that matters.

  ## What it can't tell you

  Only tilt. The estimator has no magnetometer, so rotation about gravity is
  unobservable and its yaw wanders — but yaw doesn't reach this calculation,
  since it moves the up vector not at all.

  It also can't tell a lean from an acceleration. An accelerometer measures
  specific force, so a robot accelerating forwards on the level reads as one
  leaning back, and the estimator only suppresses that to the extent its gyro
  disagrees. That is the classic failure of balancing on an IMU alone and it
  wants watching once the wheels are driving.
  """

  use BB.Sensor,
    options_schema: [
      imu_link: [
        type: :atom,
        default: :imu_link,
        doc: "The link the orientation is reported in, whose pose gives the static rotation"
      ],
      body_link: [
        type: :atom,
        default: :base_link,
        doc: "The link whose lean is being measured"
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

  alias BB.Math.{Quaternion, Transform, Vec3}
  alias BB.Message.Sensor.Imu
  alias BB.Robot.Kinematics

  @doc """
  The lean angle in radians for an orientation, positive leaning forwards.

  `body_from_imu` rotates a direction in the chip's frame into the body's.

  **Decoupled from roll**, which the obvious formula is not. Pitched by `theta`
  and rolled by `phi`, the world's up vector in body coordinates is
  `{-sin theta, cos theta * sin phi, cos theta * cos phi}` — so taking
  `atan2(-x, z)` gives `atan2(sin theta, cos theta * cos phi)`, and the roll
  shrinks the denominator. A five degree lean reads as 5.8 at thirty degrees of
  roll and 9.9 at sixty.

  That is not a rounding error on a balance bot, it is a coupling: any rolling
  motion modulates the measured lean, the controller corrects a pitch error that
  was never there, and the oscillation is driven from an axis the pitch loop
  cannot see. No gain reaches it. Dividing by the whole magnitude perpendicular
  to X instead removes `cos phi` and leaves `theta` for any roll.
  """
  @spec lean(Quaternion.t(), Quaternion.t()) :: float
  def lean(orientation, body_from_imu) do
    up = up_in_body(orientation, body_from_imu)
    y = Vec3.y(up)
    z = Vec3.z(up)

    :math.atan2(-Vec3.x(up), :math.sqrt(y * y + z * z))
  end

  @doc """
  How fast the body is leaning, in radians per second, for a gyroscope reading.
  """
  @spec lean_rate(Vec3.t(), Quaternion.t()) :: float
  def lean_rate(angular_velocity, body_from_imu) do
    body_from_imu
    |> Quaternion.rotate_vector(angular_velocity)
    |> Vec3.y()
  end

  @doc """
  The static rotation taking a direction in `imu_link`'s frame into `body_link`'s.

  Both links hang off the same joints above them, so those cancel and the
  configuration they are evaluated at doesn't matter.
  """
  @spec body_from_imu(module, atom, atom) :: Quaternion.t()
  def body_from_imu(robot_module, body_link, imu_link) do
    robot = robot_module.robot()
    body = Kinematics.forward_kinematics(robot, %{}, body_link)
    imu = Kinematics.forward_kinematics(robot, %{}, imu_link)

    body
    |> Transform.inverse()
    |> Transform.compose(imu)
    |> Transform.get_quaternion()
  end

  @impl BB.Sensor
  def init(opts) do
    %{robot: robot, path: path} = Keyword.fetch!(opts, :bb)
    body_link = Keyword.fetch!(opts, :body_link)
    imu_link = Keyword.fetch!(opts, :imu_link)

    # The chip and the estimator both publish `Imu` messages, identical but for
    # their path — the chip's orientation is always identity, since a BMI323 has
    # no magnetometer and can't fuse one on its own. Subscribing to the
    # estimator's own path takes the fused one and nothing else.
    #
    # `BB.Robot.path_to/2` builds a path the same way the supervisors do, so the
    # dozen links and joints above the IMU don't have to be named here, where
    # they would go stale the moment one was inserted.
    {:ok, link_path} = BB.Robot.path_to(robot.robot(), imu_link)

    orientation_path =
      [:sensor | link_path] ++
        [Keyword.fetch!(opts, :imu_sensor), Keyword.fetch!(opts, :orientation_estimator)]

    BB.PubSub.subscribe(robot, orientation_path, message_types: [Imu])

    {:ok,
     %{
       robot: robot,
       path: path,
       body_from_imu: body_from_imu(robot, body_link, imu_link)
     }}
  end

  @impl BB.Sensor
  def handle_info({:bb, _path, %BB.Message{payload: %Imu{} = imu}}, state) do
    BB.Sensor.publish_joint_state(state.robot, state.path,
      positions: [lean(imu.orientation, state.body_from_imu)],
      velocities: [lean_rate(imu.angular_velocity, state.body_from_imu)]
    )

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp up_in_body(orientation, body_from_imu) do
    orientation
    |> Quaternion.inverse()
    |> Quaternion.rotate_vector(Vec3.new(0.0, 0.0, 1.0))
    |> then(&Quaternion.rotate_vector(body_from_imu, &1))
  end
end
