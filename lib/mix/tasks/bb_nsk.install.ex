# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbNsk.Install do
    @shortdoc "Installs Balance Bot board support into a Nerves project"
    @moduledoc """
    #{@shortdoc}

    Establishes everything the `bb_nsk.add_*` tasks attach to: the Nerves system
    and its device tree provisioning, a robot module carrying the Balance Bot's
    measured geometry, and persistent parameters.

    It adds no hardware. The wheels, the IMU and the balance loop are separate
    tasks, so the robot can be built up a piece at a time:

    ```bash
    mix bb_nsk.add_wheels   # its wheels turn
    mix bb_nsk.add_imu      # it knows which way up it is
    mix bb_nsk.add_balance  # it stands up
    ```

    `mix bb_nsk.cheat` runs all of them.

    ## The device tree

    This writes `config/provisioning.conf`, which sets the `fit_config` U-Boot
    variable to `nsk-balance-bot`. The Trellis system ships three device trees
    and defaults to the base Nerves Starter Kit, which has no motor PWM, no
    `i2c0` on the add-on's pins and no `ledc` — so without this a freshly burned
    board reaches none of the add-on hardware.

    It only applies to a from-scratch `mix burn`. A board already burned with
    the stock value can be fixed live, taking effect on the next boot:

    ```elixir
    Nerves.Runtime.KV.put("fit_config", "nsk-balance-bot")
    ```

    It also adds `phx_install`, which `bb_nsk.add_web` needs later. A package
    added during an Igniter run is not available to that same run, so it has to
    be put in place a task ahead of the one that uses it.

    ## Example

    ```bash
    mix nerves.new my_bot --target trellis
    cd my_bot
    mix igniter.install bb_nsk
    ```

    ## Options

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    """

    use Igniter.Mix.Task

    alias Igniter.Project.{Application, Config, Deps, Formatter, Module}

    @provisioning_path "config/provisioning.conf"

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        composes: ["bb.install", "bb_parameter_store_cubdb.install"],
        # Also in `@deps` below. `adds_deps:` fetches during the run but does not
        # write to the consumer's `mix.exs`; `Deps.add_dep/2` writes but does not
        # fetch. Both, and the dependency is there and usable without anyone
        # having to run `mix deps.get` in between.
        adds_deps: [{:phx_install, "~> 0.1", only: [:dev, :test], runtime: false}],
        schema: [robot: :string],
        aliases: [r: :robot]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      robot_module = BB.Igniter.robot_module(igniter)

      igniter
      |> check_nerves()
      |> Formatter.import_dep(:bb_nsk)
      |> create_robot_module(robot_module)
      # `--backend binary` because neither EXLA nor Torchx is worth
      # cross-compiling for a dual Cortex-A7, and this robot does no IK — the
      # hot path holds its vectors and quaternions as plain floats and never
      # reaches Nx at all.
      |> Igniter.compose_task("bb.install", [
        "--robot",
        inspect(robot_module),
        "--backend",
        "binary"
      ])
      |> Igniter.compose_task("bb_parameter_store_cubdb.install", [
        "--robot",
        inspect(robot_module)
      ])
      |> name_the_robot()
      |> add_deps()
      |> add_nerves_system()
      |> write_provisioning()
    end

    # Igniter can't scaffold a Nerves project and shouldn't pretend to — the
    # config files, the release and the target machinery all come from
    # `nerves.new`, and a project without them would fail much later and much
    # less clearly than this.
    defp check_nerves(igniter) do
      if Deps.has_dep?(igniter, :nerves) do
        igniter
      else
        Mix.raise("""
        bb_nsk installs into an existing Nerves project, and this one has no
        `:nerves` dependency.

            mix nerves.new my_bot --target trellis
            cd my_bot
            mix igniter.install bb_nsk
        """)
      end
    end

    # Created whole rather than composed from `bb.add_robot`'s skeleton and then
    # patched: the standing topology wraps `base_link` in the two joints the
    # robot is free to move through, and no amount of filling in an empty
    # `link :base_link do end` can put ancestors above it. `bb.add_robot` skips
    # creation when the module is already there, so composing it afterwards
    # still wires up the supervision tree.
    defp create_robot_module(igniter, robot_module) do
      case Module.module_exists(igniter, robot_module) do
        {true, igniter} ->
          igniter

        {false, igniter} ->
          Module.create_module(igniter, robot_module, robot_contents())
      end
    end

    # `phx_install` is added here rather than by `bb_nsk.add_web`, which is the
    # task that actually wants it, because a package added during an Igniter run
    # is not on the code path for that same run to compose. Putting it in place a
    # task earlier means `add_web` can reach `phx.install.core` and friends, and
    # nobody has to know why. Dev and test only — it is a code generator, and
    # generators have no business in a firmware image.
    #
    # The others are the hardware access the wheels and the IMU need. All of them
    # go in with `Deps.add_dep/2`, because `adds_deps:` fetches without writing
    # to `mix.exs` and a project that only builds while `bb_nsk` is a path
    # dependency is not a project that works.
    @deps [
      {:circuits_gpio, "~> 2.1"},
      {:circuits_i2c, "~> 2.1"},
      {:phx_install, "~> 0.1", only: [:dev, :test], runtime: false}
    ]

    # Nothing in this package can work the robot's name out for itself — its own
    # OTP application is `:bb_nsk`, so a robot asking gets the library's name
    # back. That is how a board came up with `BB_NSK` across the top of its panel.
    #
    # Set here rather than by the tasks that use it, because the panel and the
    # access point both want it and neither implies the other.
    defp name_the_robot(igniter) do
      Config.configure(
        igniter,
        "config.exs",
        :bb_nsk,
        [:name],
        to_string(Application.app_name(igniter))
      )
    end

    defp add_deps(igniter), do: Enum.reduce(@deps, igniter, &Deps.add_dep(&2, &1))

    # `mix nerves.new --target trellis` pins `~> 0.4`, and this bumps it without
    # asking. 0.5.0 is the first release whose FIT image carries the
    # `nsk-balance-bot` device tree at all, so on 0.4 there is nothing for the
    # provisioning below to select and none of the add-on hardware is reachable.
    #
    # It is not a free upgrade, which is why it is called out rather than done
    # quietly: 0.5.0 moved from syslinux to FIT boot and put U-Boot updates in
    # their own fwup task, so a board already running 0.4.2 or earlier needs a
    # FEL reflash. `mix upload` would write a FIT image under a bootloader that
    # cannot read one.
    defp add_nerves_system(igniter) do
      igniter
      |> Deps.add_dep(
        {:nerves_system_trellis, "~> 0.5", runtime: false, targets: :trellis},
        yes?: true
      )
      |> Igniter.add_notice("""
      nerves_system_trellis was set to ~> 0.5, which is the first release
      carrying the nsk-balance-bot device tree.

      If this board is currently running 0.4.2 or earlier, it needs a FEL
      reflash rather than `mix upload` — 0.5.0 switched to FIT boot, and an OTA
      would write an image the installed bootloader cannot read.
      """)
    end

    # `config :nerves, :firmware, provisioning:` hangs off the system's own
    # `define(NERVES_PROVISIONING, ...)`, which fwup lets an environment
    # variable of the same name override. The include sits inside the
    # `complete` task immediately after the U-Boot environment is written, so
    # this beats the baked-in default rather than being overwritten by it.
    defp write_provisioning(igniter) do
      igniter
      |> Igniter.create_new_file(@provisioning_path, provisioning_contents(), on_exists: :skip)
      |> Config.configure(
        "config.exs",
        :nerves,
        [:firmware, :provisioning],
        @provisioning_path
      )
    end

    defp provisioning_contents do
      """
      # fwup instructions run when a board is burned from scratch, replacing the
      # ones the Trellis system ships. Included by `fwup.conf`'s `complete` task
      # after the default U-Boot environment is written, so anything set here
      # overrides it.

      # Carried over from the system's own provisioning.conf. The '$' is escaped
      # so the substitution happens at burn time rather than firmware build
      # time, which keeps serial numbers out of the .fw file.
      uboot_setenv(uboot-env, "nerves_serial_number", "\\${NERVES_SERIAL_NUMBER}")

      # U-Boot picks a device tree out of the FIT image by this name, and the
      # system defaults it to the base Nerves Starter Kit, which reaches none of
      # the Beam Bots add-on board. Without this a freshly burned board comes up
      # with no IMU, no motor PWM and no NeoPixels until someone sets it by hand.
      #
      # The upgrade tasks don't rewrite the U-Boot environment, so this only
      # applies to a from-scratch burn — which is also the only thing that
      # resets it.
      uboot_setenv(uboot-env, "fit_config", "nsk-balance-bot")
      """
    end

    defp robot_contents do
      """
      use BB

      import BB.Unit

      commands do
        command :arm do
          handler(BB.Command.Arm)
          allowed_states([:disarmed])
        end

        command :disarm do
          handler(BB.Command.Disarm)
          allowed_states([:idle])
        end
      end

      # From the CAD model, taking the wheel axis as the reference. The axis is
      # 16mm above the bottom of the body and 8.6mm ahead of its back face, so
      # the body's centre is 124/2 - 16 = 46mm above it and 20.7/2 - 8.6 =
      # 1.75mm ahead of it.
      @body_depth ~u(20.7 millimeter)
      @body_width ~u(99 millimeter)
      @body_height ~u(124 millimeter)
      @body_centre_ahead ~u(1.75 millimeter)
      @body_centre_above ~u(46 millimeter)

      # Half of a 43mm wheel. The axis is 16mm above the bottom of the body, so
      # the body clears the ground by 5.5mm — anything under a 32mm wheel would
      # leave it resting on the ground with the wheels spinning in the air.
      @wheel_radius ~u(21.5 millimeter)

      # Weighed with the wheels off. They hang off their own links, and a
      # wheel's mass sits on the axle where it makes no toppling torque, so the
      # body alone is the pendulum.
      @body_mass ~u(138 gram)

      # The height is measured: 61.5mm above the bottom of the body, so 45.5mm
      # above the wheel axis.
      #
      # The fore-aft is NOT measured. A knife edge said 8.1mm, and the robot
      # would not balance anywhere near the -10.1 degrees that implies; -3
      # degrees is a value found by trying values until one worked, and 2.4mm is
      # what `x = z * tan(3)` makes of it — kept here only so the geometry and
      # the setpoint tell the same story.
      #
      # Measuring it properly is available and nobody has done it: start the
      # trim at zero on a flat floor, let it settle until the mean wheel command
      # is about nothing, and read `setpoint + trim`. That angle is the centre
      # of mass.
      @com_ahead ~u(2.4 millimeter)
      @com_above ~u(45.5 millimeter)

      # A uniform box of the body's dimensions, about its centre of mass:
      # m(y²+z²)/12 and so on for 138g and 20.7 x 99 x 124mm. The mass is not
      # uniform — the panel is on the front and the battery is one lump — so
      # these are an approximation, but not a negligible one: about the wheel
      # axis the body's own pitch inertia is a third of the total, the rest
      # being m*l².
      @body_ixx ~u(2895 gram_square_centimeter)
      @body_iyy ~u(1818 gram_square_centimeter)
      @body_izz ~u(1176 gram_square_centimeter)
      @no_inertia ~u(0 gram_square_centimeter)

      topology do
        # The robot is not bolted to anything, so the chain starts at the world
        # and the body reaches it through the two ways it is free to move: the
        # wheels carry it around the ground, and it leans about the wheel axis.
        #
        # Neither of those joints has an actuator. The lean is observable — it
        # is what the IMU and its filter report — but the ground pose is not,
        # because there are no encoders, so it stays at identity rather than
        # being dead reckoned from what the wheels were asked to do.
        #
        # A tree cannot express the rolling constraint either. Wheel rotation
        # and travel across the ground are physically coupled, but that is a
        # loop, so odometry stays a calculation beside this rather than
        # something forward kinematics gives us.
        link :world do
          joint :ground do
            type(:planar)

            axis do
            end

            link :ground_contact do
              joint :lean do
                type(:revolute)
                # Pitch about +Y, so leaning forwards is positive. The joint
                # sits a wheel radius above the ground, because that is where
                # the axis is.
                axis(roll: ~u(-90 degree))
                origin(z: @wheel_radius)

                limit(
                  lower: ~u(-90 degree),
                  upper: ~u(90 degree),
                  effort: ~u(0 newton_meter),
                  velocity: ~u(0 radian_per_second)
                )

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
  defmodule Mix.Tasks.BbNsk.Install do
    @shortdoc "Installs Balance Bot board support into a Nerves project"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The bb_nsk.install task requires igniter.

          mix igniter.install bb_nsk
      """)

      exit({:shutdown, 1})
    end
  end
end
