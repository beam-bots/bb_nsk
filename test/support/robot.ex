# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.TestRobot do
  @moduledoc """
  The Balance Bot's topology, with nothing attached to it.

  The same robot the installer writes into a user's project, minus the IMU. The
  BMI323 driver stops rather than declining when the chip isn't there, which on
  the host would take the supervision tree with it, so the tests publish onto the
  estimator's path directly instead.

  The wheels are declared and will decline to start — there is no `pwmchip0` on
  a laptop — which is the behaviour a robot missing its hardware is supposed to
  have, and is worth exercising.

  Anything here that disagrees with the `bb_nsk.add_*` tasks is a bug in one of
  them.
  """

  use BB

  import BB.Unit

  commands do
    # A custom handler so that arming lands in the state the robot's attitude
    # calls for rather than always in `:idle`. `arm true` keeps `BB.Safety.arm/1`
    # routing through the command system.
    command :arm do
      handler(BB.NSK.Command.Arm)
      allowed_states([:disarmed])
      arm(true)
    end

    # Disarming has to be reachable from every state the robot can get stuck in,
    # or a robot that has fallen over can't be switched off.
    command :disarm do
      handler(BB.Command.Disarm)
      allowed_states([:idle, :balancing, :fallen])
    end

    command :stand do
      handler(BB.NSK.Command.Stand)
      allowed_states([:idle, :fallen])
    end

    # From `:idle` as well as `:balancing`, because a robot armed while already
    # on its side has fallen over without ever having balanced.
    command :fall do
      handler(BB.NSK.Command.Fall)
      allowed_states([:balancing, :idle])
    end

    # There is no power button, and pulling the battery on a robot mid-write to
    # its application partition is how a configuration goes missing.
    #
    # Disarmed only: taking the operating system out from under a balancing
    # robot drops it on the floor. `disarm` reaches every state the robot can
    # get stuck in, so there is always a way through to here.
    command :poweroff do
      handler(BB.NSK.Command.Poweroff)
      allowed_states([:disarmed])
    end
  end

  states do
    state(:balancing, doc: "Actively holding itself upright")
    state(:fallen, doc: "Past recovering, wheels braked, waiting to be stood back up")
  end

  # A robot-level sensor rather than one on a link: it reads the air, not a
  # frame. That is also what puts its readings on `[:sensor, :environment]`,
  # which is where the display controller listens.
  sensors do
    sensor(:environment, BB.NSK.Sensor.Environment)
  end

  controllers do
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
  end

  parameters do
    group :balance do
      param(:setpoint,
        type: {:unit, :degree},
        default: ~u(-3 degree),
        min: ~u(-30 degree),
        max: ~u(30 degree),
        doc: "The lean the balance controller holds, negative leaning back"
      )

      param(:proportional_gain,
        type: :float,
        default: 180.0,
        min: 0.0,
        max: 250.0,
        doc: "Wheel velocity per radian of lean error, in 1/s"
      )

      param(:derivative_gain,
        type: :float,
        default: 4.0,
        min: 0.0,
        max: 20.0,
        doc: "Wheel velocity per radian per second of lean rate"
      )

      param(:trim_gain,
        type: :float,
        default: 0.01,
        min: 0.0,
        max: 1.0,
        doc: "How fast the setpoint chases away a persistent wheel command"
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
    end

    # Parameter names are unique across *every* group, not just within one, so
    # these cannot be `:limit` and `:slew` — `:yaw` already has a `:limit`.
    group :drive do
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
        doc: "How fast the drive lean may change"
      )

      param(:release,
        type: {:unit, :degree_per_second},
        default: ~u(32 degree_per_second),
        min: ~u(1 degree_per_second),
        max: ~u(180 degree_per_second),
        doc: "How fast the drive lean returns towards zero"
      )
    end

    group :yaw do
      param(:gain,
        type: :float,
        default: 16.0,
        min: 0.0,
        max: 50.0,
        doc: "Differential wheel velocity per radian of heading error, in 1/s"
      )

      param(:damping,
        type: :float,
        default: 0.5,
        min: 0.0,
        max: 20.0,
        doc: "Differential wheel velocity per radian per second of yaw rate"
      )

      param(:limit,
        type: :float,
        default: 3.0,
        min: 0.0,
        max: 15.0,
        doc: "How much wheel velocity the heading may spend, in rad/s"
      )

      param(:tau,
        type: :float,
        default: 10.0,
        min: 0.5,
        max: 120.0,
        doc: "Seconds for the held heading to follow the measured one"
      )
    end

    group :motor do
      param(:deadband,
        type: :float,
        default: 0.01,
        min: 0.0,
        max: 0.9,
        doc: "Duty below which the motor doesn't turn, as a fraction of full scale"
      )
    end
  end

  topology do
    # The robot is not bolted to anything, so the chain starts at the world and
    # the body reaches it through the two ways it is free to move: the wheels
    # carry it around the ground, and it leans about the wheel axis.
    #
    # Neither of those joints has an actuator. The lean is observable — it is
    # what the IMU and its filter report — but the ground pose is not, because
    # there are no encoders, so it stays at identity rather than being dead
    # reckoned from what the wheels were asked to do.
    #
    # A tree cannot express the rolling constraint either. Wheel rotation and
    # travel across the ground are physically coupled, but that is a loop, so
    # odometry stays a calculation beside this rather than something forward
    # kinematics gives us.
    link :world do
      joint :ground do
        type(:planar)

        axis do
        end

        # The heading is observable even though the position isn't: the gyro
        # measures yaw rate directly, and integrating it is a real angle where
        # dead reckoning `x` and `y` from wheel commands would be a fiction.
        sensor(:heading, BB.NSK.Sensor.Heading)

        link :ground_contact do
          joint :lean do
            type(:revolute)
            # Pitch about +Y, so leaning forwards is positive. The joint sits a
            # wheel radius above the ground, because that is where the axis is.
            axis(roll: ~u(-90 degree))
            origin(z: ~u(21.5 millimeter))

            limit(
              lower: ~u(-90 degree),
              upper: ~u(90 degree),
              effort: ~u(0 newton_meter),
              velocity: ~u(0 radian_per_second)
            )

            # No actuator, but the lean is observable: the IMU hangs off a link
            # below this joint, and what it reports about gravity is exactly
            # this joint's configuration.
            sensor(:lean_angle, BB.NSK.Sensor.Lean)

            link :base_link do
              visual do
                box(x: ~u(20.7 millimeter), y: ~u(99 millimeter), z: ~u(124 millimeter))
                origin(x: ~u(1.75 millimeter), z: ~u(46 millimeter))
              end

              inertial do
                origin(x: ~u(2.4 millimeter), z: ~u(45.5 millimeter))
                mass(~u(138 gram))

                inertia(
                  ixx: ~u(2895 gram_square_centimeter),
                  iyy: ~u(1818 gram_square_centimeter),
                  izz: ~u(1176 gram_square_centimeter),
                  ixy: ~u(0 gram_square_centimeter),
                  ixz: ~u(0 gram_square_centimeter),
                  iyz: ~u(0 gram_square_centimeter)
                )
              end

              # `BB.Sensor.BMI323` publishes in the chip's own axes and a
              # `sensor` has no origin of its own — the link it hangs off is its
              # frame — so the mounting is a link of its own, and everything
              # downstream gets the transform from the kinematics rather than
              # hard-coding a swap.
              #
              # The board stands upright across the front of the body, so the
              # chip's +Z faces forwards, its +Y points at the floor and its +X
              # to the robot's right. Read off the gravity vector in two
              # attitudes rather than off the silkscreen: on its back the whole
              # g lands on +Z, and on its wheels it lands on -Y. Those two fix
              # the third, since the chip's frame is right handed.
              #
              # Where it sits and how it is turned are two joints rather than one
              # origin carrying both, because `BB.Math.Transform.from_origin/1`
              # composes the rotation before the translation — so an origin with
              # both would place the chip at its own offset seen through its own
              # quarter turn, 29.5mm forward of the axis instead of 29.5mm above
              # it. Splitting them means neither joint has a rotation and a
              # translation at once, which is the same answer either way round.
              joint :imu_mount_joint do
                type(:fixed)
                origin(x: ~u(-4.9 millimeter), z: ~u(29.5 millimeter))

                link :imu_mount do
                  joint :imu_joint do
                    type(:fixed)
                    origin(pitch: ~u(90 degree), yaw: ~u(-90 degree))

                    link :imu_link do
                    end
                  end
                end
              end

              # Which way round the two PWM channels go is confirmed against the
              # hardware, driving each wheel and watching which way the robot
              # goes. Forwards means towards +X, which the kinematic model
              # anchors to the face that points at the ceiling when the robot is
              # laid on its back — the same convention the IMU's mounting was
              # measured against.
              joint :left_wheel_joint do
                type(:continuous)
                axis(roll: ~u(-90 degree))
                origin(y: ~u(55 millimeter))

                limit(effort: ~u(0.2 newton_meter), velocity: ~u(20 radian_per_second))

                actuator(
                  :left_wheel,
                  {BB.NSK.Wheel,
                   forward_pwm: 3,
                   reverse_pwm: 2,
                   enable_pin: "PE6",
                   deadband: param([:motor, :deadband])}
                )

                link :left_wheel_link do
                  # A wheel's mass is on its own axis, so its centre of mass is
                  # the link's origin and needs no offset.
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

              joint :right_wheel_joint do
                type(:continuous)
                axis(roll: ~u(-90 degree))
                origin(y: ~u(-55 millimeter))

                limit(effort: ~u(0.2 newton_meter), velocity: ~u(20 radian_per_second))

                actuator(
                  :right_wheel,
                  {BB.NSK.Wheel,
                   forward_pwm: 5,
                   reverse_pwm: 4,
                   enable_pin: "PE11",
                   deadband: param([:motor, :deadband])}
                )

                link :right_wheel_link do
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
            end
          end
        end
      end
    end
  end
end
