# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbNsk.AddDisplay do
    @shortdoc "Adds the 4.2\" e-paper panel and the status screen it draws"
    @moduledoc """
    #{@shortdoc}

    Adds the renderer, the panel driver and the controller that decides when to
    redraw, plus the dependencies and configuration all three need.

    The panel shows network, robot and system status — including, when the robot
    is running its own access point, the passphrase for it. That is the only
    place that passphrase can be read, since it is derived from the board's
    serial number rather than stored anywhere.

    ## Redraws are driven by change, not by a clock

    A refresh takes the better part of three seconds, so the controller watches
    the robot's safety state and the WiFi interface and coalesces a burst of
    changes into one redraw. A slower periodic redraw keeps uptime and load from
    going stale and does the full refresh that clears the ghosting the partial
    ones leave behind.

    ## Nothing walks a pixel in Elixir

    Emerge rasterises with Skia in a Rustler NIF and packs to one or two bits per
    pixel on the Rust side. That is the point: the panel is 120,000 pixels and
    15,000 bytes, and anything that walks that in Elixir costs about as long as
    the panel takes to show it.

    Which is also why this task adds two aliases to your `mix.exs`. The NIF cache
    is shared between every build, so a host `mix test` leaves an `x86_64`
    library where the firmware build can see it and Nerves' release scrub rejects
    the whole image. `BB.NSK.MixHelpers` handles the host and target copies as a
    pair; see its docs for the whole story.

    ## Two of the three dependencies are not on Hex

    `eink` is a git branch — the packed-greyscale UC8276 driver and the
    imperative API are only there — and `emerge` is a beta. Both are deliberate
    and temporary.

    ## Example

    ```bash
    mix bb_nsk.add_display
    ```

    Check it end to end, once the firmware is on a board:

    ```elixir
    BB.NSK.Display.TestCard.show(MyBot.Robot)
    ```

    ## Options

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Common
    alias Igniter.Project.{Application, Config, Deps, TaskAliases}

    # Added with `Deps.add_dep/2` rather than declared in `adds_deps:`. The
    # latter is for dependencies that must be fetched and compiled *before* the
    # task runs, and it does not reliably reach `mix.exs` when the task is
    # composed — `bb_nsk.cheat` produced a project with none of these.
    @deps [
      {:eink, git: "https://github.com/emerge-elixir/eink.git", branch: "feat/imperative-gray2"},
      {:emerge, "== 0.4.0-beta.1"},
      {:video_interop, "~> 0.1.1"},
      # Only needed when the NIF has to be built from source rather than
      # downloaded, which on this board it no longer does. Kept so that a source
      # build remains possible when diagnosing the precompiled one.
      {:rustler, "~> 0.38", runtime: false}
    ]

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        schema: [robot: :string],
        aliases: [r: :robot]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      robot_module = BB.Igniter.robot_module(igniter)

      igniter
      |> add_deps()
      |> configure_emerge()
      |> configure_panel()
      |> add_nif_aliases()
      |> add_supervisor()
      |> BB.Igniter.add_controller(robot_module, :display, controller())
    end

    defp add_deps(igniter), do: Enum.reduce(@deps, igniter, &Deps.add_dep(&2, &1))

    # The board is a Cortex-A7 with no GPU worth rendering through, and an empty
    # backend list selects Emerge's minimal raster artefact — its `embedded-cpu`
    # Rust profile. Left unset it picks the OpenGL build instead, which is larger
    # and buys this panel nothing: an e-paper refresh takes seconds and the
    # renderer is nowhere near the cost of one.
    defp configure_emerge(igniter) do
      igniter
      |> Config.configure("config.exs", :emerge, [:compiled_backends], [])
      |> Config.configure("config.exs", :emerge, [:compiled_vulkan_backends], [])
    end

    # 10 MHz is what the bus was measured doing — 15,000 bytes in 11 ms — rather
    # than the 100 kHz the driver used to ask for and never honour. `palette` is
    # the default a draw uses when it names none; the frame sink names one on
    # every draw.
    #
    # Target-only: there is no panel on a laptop, and `EInk` is a singleton
    # GenServer that would fail to start without one.
    defp configure_panel(igniter) do
      Igniter.create_or_update_elixir_file(
        igniter,
        "config/target.exs",
        """
        import Config

        #{panel_config()}
        """,
        fn zipper -> {:ok, Common.add_code(zipper, panel_config())} end
      )
    end

    defp panel_config do
      """
      config :eink,
        driver: EInk.Driver.UC8276,
        width: 400,
        height: 300,
        palette: :bw,
        driver_config: [
          spi_device: "spidev0.0",
          dc_pin: "EPD_DC",
          reset_pin: "EPD_RESET",
          busy_pin: "EPD_BUSY",
          spi_opts: [speed_hz: 10_000_000]
        ]
      """
    end

    # The function references have to go in as code rather than as strings.
    # A string in an alias list is a task name, so `mix firmware` would look for
    # a task literally called "&BB.NSK.MixHelpers.prune_host_nifs/1" and stop.
    defp add_nif_aliases(igniter) do
      igniter
      |> TaskAliases.add_alias("firmware", alias_for(:prune_host_nifs, "firmware"))
      |> TaskAliases.add_alias("test", alias_for(:restore_host_nifs, "test"))
      |> TaskAliases.add_alias("run", alias_for(:restore_host_nifs, "run"))
    end

    defp alias_for(function, task) do
      [{:code, Sourceror.parse_string!("&BB.NSK.MixHelpers.#{function}/1")}, task]
    end

    # Ahead of the robot, so the panel is still there when the robot's display
    # controller shuts down and asks for the screen to be blanked — children
    # terminate in the reverse of the order they start in.
    defp add_supervisor(igniter) do
      Application.add_new_child(igniter, BB.NSK.Display.Supervisor, before: [:robot])
    end

    defp controller do
      """
      controller(:display, BB.NSK.Display.Controller)
      """
    end
  end
else
  defmodule Mix.Tasks.BbNsk.AddDisplay do
    @shortdoc "Adds the e-paper panel and the status screen it draws"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("The bb_nsk.add_display task requires igniter.")
      exit({:shutdown, 1})
    end
  end
end
