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
  end

  states do
    state(:balancing, doc: "Actively holding itself upright")
    state(:fallen, doc: "Past recovering, wheels braked, waiting to be stood back up")
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

  # From the CAD model, taking the wheel axis as the reference. The axis is 16mm
  # above the bottom of the body and 8.6mm ahead of its back face, so the body's
  # centre is 124/2 - 16 = 46mm above it and 20.7/2 - 8.6 = 1.75mm ahead of it.
  @body_depth ~u(20.7 millimeter)
  @body_width ~u(99 millimeter)
  @body_height ~u(124 millimeter)
  @body_centre_ahead ~u(1.75 millimeter)
  @body_centre_above ~u(46 millimeter)

  # Half of a 43mm wheel. The axis is 16mm above the bottom of the body, so the
  # body clears the ground by 5.5mm — anything under a 32mm wheel would leave it
  # resting on the ground with the wheels spinning in the air.
  @wheel_radius ~u(21.5 millimeter)

  # NOT MEASURED. The track is what turns a difference in wheel speed into yaw.
  # Defined as a pair so that changing it can't move one wheel and not the other.
  #
  # The heading hold does not depend on it: the loop is feedback, so the yaw gain
  # absorbs whatever the real track is and only the *sign* has to be right, which
  # is confirmed on hardware. What the guess costs is that the gain has no
  # physical meaning — it cannot be predicted from geometry, only swept.
  @left_wheel_y ~u(55 millimeter)
  @right_wheel_y ~u(-55 millimeter)

  # Measured on the robot: 45.5mm above the bottom of the body, on the
  # centreline, 17mm back from the front face. Against the wheel axis that is
  # 45.5 - 16 = 29.5mm up, and the front face is 20.7 - 8.6 = 12.1mm ahead of the
  # axis, so 12.1 - 17 = 4.9mm behind it.
  @imu_ahead ~u(-4.9 millimeter)
  @imu_above ~u(29.5 millimeter)

  # Weighed with the wheels off. They hang off their own links, and a wheel's
  # mass sits on the axle where it makes no toppling torque, so the body alone
  # is the pendulum.
  @body_mass ~u(138 gram)
  @wheel_mass ~u(15 gram)

  # The height is measured: 61.5mm above the bottom of the body, so 45.5mm above
  # the wheel axis.
  #
  # The fore-aft is NOT measured. A knife edge said 8.1mm, and the robot would
  # not balance anywhere near the -10.1 degrees that implies; -3 degrees is a
  # value found by trying values until one worked, and 2.4mm is what
  # `x = z * tan(3)` makes of it — kept here only so the geometry and the
  # setpoint tell the same story. Its real precision is unknown and probably no
  # better than a degree, which is a millimetre.
  #
  # Measuring it properly is available and nobody has done it: start the trim at
  # zero on a flat floor, let it settle until the mean wheel command is about
  # nothing, and read `setpoint + trim`. That angle is the centre of mass.
  @com_ahead ~u(2.4 millimeter)
  @com_above ~u(45.5 millimeter)

  # A uniform box of the body's dimensions, about its centre of mass: m(y²+z²)/12
  # and so on for 138g and 20.7 x 99 x 124mm. The mass is not uniform — the panel
  # is on the front and the battery is one lump — so these are an approximation,
  # but not a negligible one: about the wheel axis the body's own pitch inertia
  # is a third of the total, the rest being m*l².
  @body_ixx ~u(2895 gram_square_centimeter)
  @body_iyy ~u(1818 gram_square_centimeter)
  @body_izz ~u(1176 gram_square_centimeter)

  # A uniform disc of 15g at a 21.5mm radius: mr²/2 about the axle it spins on,
  # mr²/4 across. A tyred wheel carries more of its mass at the rim than a disc
  # does, so the spin figure is a floor, but at three orders of magnitude below
  # the body's it makes no odds.
  @wheel_spin_inertia ~u(34.67 gram_square_centimeter)
  @wheel_transverse_inertia ~u(17.33 gram_square_centimeter)
  @no_inertia ~u(0 gram_square_centimeter)

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
            origin(z: @wheel_radius)

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
                box(x: @body_depth, y: @body_width, z: @body_height)
                origin(x: @body_centre_ahead, z: @body_centre_above)
              end

              inertial do
                origin(x: @com_ahead, z: @com_above)
                mass(@body_mass)

                inertia(
                  ixx: @body_ixx,
                  iyy: @body_iyy,
                  izz: @body_izz,
                  ixy: @no_inertia,
                  ixz: @no_inertia,
                  iyz: @no_inertia
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
                origin(x: @imu_ahead, z: @imu_above)

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
                origin(y: @left_wheel_y)

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
                    mass(@wheel_mass)

                    inertia(
                      ixx: @wheel_transverse_inertia,
                      iyy: @wheel_spin_inertia,
                      izz: @wheel_transverse_inertia,
                      ixy: @no_inertia,
                      ixz: @no_inertia,
                      iyz: @no_inertia
                    )
                  end
                end
              end

              joint :right_wheel_joint do
                type(:continuous)
                axis(roll: ~u(-90 degree))
                origin(y: @right_wheel_y)

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
                    mass(@wheel_mass)

                    inertia(
                      ixx: @wheel_transverse_inertia,
                      iyy: @wheel_spin_inertia,
                      izz: @wheel_transverse_inertia,
                      ixy: @no_inertia,
                      ixz: @no_inertia,
                      iyz: @no_inertia
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
