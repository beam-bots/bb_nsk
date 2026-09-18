# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbNsk.AddWeb do
    @shortdoc "Adds the drive pad, the wifi setup page and the Phoenix they need"
    @moduledoc """
    #{@shortdoc}

    Gets Phoenix into a Nerves project that has none, mounts the `bb_liveview`
    dashboard, and writes two pages of its own: a thumb pad for driving the
    robot from a phone, and a page for telling it about a network.

    Those two are **generated into your project rather than mounted from this
    library**. A library carrying Phoenix, tailwind and esbuild assets is
    awkward to depend on and worse to customise, and the drive pad is the part
    of this an attendee most obviously wants to change. Only
    `BB.NSK.Drive` and its message stay here, because what the pad publishes and
    what the balance controller consumes has to be the same on both sides.

    ## It needs Phoenix already

    Bootstrapping Phoenix is a separate step, and deliberately so. A package
    added during an Igniter run is not on the code path for that same run to
    compose — so a task that added `phx_install` and then tried to use it would
    have to be run twice to work, and would look broken the first time. One
    command up front is clearer than that:

    ```bash
    mix igniter.install phx_install
    mix bb_nsk.add_web
    ```

    This task checks, and tells you the same thing if you forget.

    ## Phoenix on a Nerves target is not Phoenix on a server

    Once Phoenix is there, this mounts the `bb_liveview` dashboard and fixes the
    half-dozen places where a board differs from a server:

    - `tailwind` and `heroicons` are scoped `targets: :host, only: [:dev]`, or
      they get cross-compiled into firmware that wants neither. `esbuild` only
      gets `runtime: false`: `bb_liveview` depends on it for every target, and
      Nerves refuses a dependency scoped more narrowly than its dependent.
    - `lazy_html` is added for `Phoenix.LiveViewTest`, which needs a DOM parser
      and doesn't bring one.
    - `sourceror` is added because `.formatter.exs` runs `Spark.Formatter`
      through `import_deps: [:bb]` and nothing else declares it.
    - the live-reload patterns in `config/dev.exs` get the `E` modifier, without
      which `mix firmware` fails at the release step.
    - `config/runtime.exs` gets an endpoint block under `config_target() != :host`
      binding `[::]:80` with `server: true`. There is no `mix phx.server` on a
      device, and `mix nerves.new` generates no `runtime.exs` at all, so this
      creates it.

    The endpoint is added to the supervision tree **after** the robot and the
    network, because children terminate in reverse start order and a robot
    nobody can reach is a robot nobody can fix.

    ## Example

    ```bash
    mix bb_nsk.add_wifi   # so there is a network to reach it on
    mix bb_nsk.add_web
    ```

    ## Options

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    * `--auto-phoenix` - Install Phoenix without asking. `mix bb_nsk.cheat`
      passes this; run the task by hand and it will ask first.
    * `--path` - Where to mount the bb_liveview dashboard (default `/`).
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Common
    alias Igniter.Libs.Phoenix
    alias Igniter.Project.{Application, Deps}

    @host_only [targets: :host, only: [:dev]]

    # `esbuild` is deliberately not in the list. `bb_liveview` depends on it for
    # every target, and Nerves refuses a dependency whose `:targets` is narrower
    # than a dependent's — the firmware build fails at `deps.get` with "does not
    # match the :targets option calculated for". Scoping its *runtime* is the
    # part that can be done from here.
    @host_only_deps [:tailwind, :heroicons]

    # The five a LiveView dashboard needs, skipping ecto, mailer, gettext, page,
    # dashboard, heroicons and components — the same set `bb_liveview` picked,
    # and for the same reason: a robot has no use for them.
    #
    # Gettext in particular has to stay out. `phx.install.gettext` writes
    # `gettext ~> 0.26` into the project, and `bb` reaches `localize`, which
    # wants `~> 1.0` — so the two cannot be resolved together. Running
    # `mix igniter.install phx_install` rather than these subtasks hits exactly
    # that, because its `--no-gettext` flag gates the generator and not the
    # dependency.
    @phoenix_subtasks [
      "phx.install.core",
      "phx.install.endpoint",
      "phx.install.router",
      # composes `phx.install.html` itself
      "phx.install.live",
      "phx.install.assets"
    ]

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        # `installs:` rather than `adds_deps:`. `bb_liveview` is not a dependency
        # of this package — a robot that only balances has no use for Phoenix —
        # and only `installs:` both fetches it *and* puts its installer on the
        # code path, which is what `compose_task/2` needs below. `adds_deps:`
        # fetches without the second half, and the compose then fails.
        #
        composes: ["bb_liveview.install"] ++ @phoenix_subtasks,
        schema: [robot: :string, path: :string],
        aliases: [r: :robot]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      robot_module = BB.Igniter.robot_module(igniter)
      path = Keyword.get(igniter.args.options, :path, "/dashboard")

      case Phoenix.select_router(igniter) do
        {igniter, nil} -> bootstrap_phoenix(igniter, robot_module, path)
        {igniter, _router} -> add_web(igniter, robot_module, path)
      end
    end

    defp bootstrap_phoenix(igniter, robot_module, path) do
      if Code.ensure_loaded?(Mix.Tasks.Phx.Install.Core) do
        igniter
        |> then(
          &Enum.reduce(@phoenix_subtasks, &1, fn task, acc ->
            Igniter.compose_task(acc, task, [])
          end)
        )
        |> add_web(robot_module, path)
      else
        needs_phx_install(igniter)
      end
    end

    defp needs_phx_install(igniter) do
      Igniter.add_warning(igniter, """
      bb_nsk.add_web found no Phoenix and no `phx_install` to build one with, so
      it added nothing. Add the dependency and run this again:

          mix igniter.add phx_install
          mix deps.get
          mix bb_nsk.add_web

      `mix igniter.install phx_install` would also work, and then fail: its
      orchestrator adds `gettext ~> 0.26`, and `bb` reaches `localize`, which
      wants `~> 1.0`. `igniter.add` adds the dependency without running it.
      """)
    end

    defp add_web(igniter, robot_module, path) do
      igniter
      |> Igniter.compose_task("bb_liveview.install", [
        "--robot",
        inspect(robot_module),
        "--path",
        path
      ])
      |> scope_asset_deps()
      |> add_test_deps()
      |> write_runtime_config()
      |> fix_live_reload_patterns()
      |> generate_pages(robot_module)
      |> order_the_endpoint()
    end

    # Left unscoped these are cross-compiled into the firmware, which has no use
    # for a CSS toolchain or an icon set.
    defp scope_asset_deps(igniter) do
      igniter
      |> then(&Enum.reduce(@host_only_deps, &1, fn dep, acc -> rescope(acc, dep, @host_only) end))
      |> rescope(:esbuild, runtime: false)
    end

    # Keeps whatever version the Phoenix installer chose and only narrows where
    # the dependency applies — replacing the requirement with `>= 0.0.0` would
    # silently widen it while claiming to be a scoping change.
    defp rescope(igniter, name, opts) do
      case Deps.get_dep(igniter, name) do
        {:ok, nil} -> igniter
        {:ok, current} -> Deps.add_dep(igniter, {name, version(current), opts}, yes?: true)
        _error -> igniter
      end
    end

    defp version(current) do
      case Code.eval_string(current) do
        {{_name, version}, _binding} when is_binary(version) -> version
        {{_name, version, _opts}, _binding} when is_binary(version) -> version
        _other -> ">= 0.0.0"
      end
    end

    defp add_test_deps(igniter) do
      igniter
      # `Phoenix.LiveViewTest` needs a DOM parser and does not bring one itself.
      #
      # `only:` and no `targets:`. A dep excluded from every environment the
      # firmware is built in is already absent from it, and adding a `:targets`
      # restriction on top only invites Nerves' "does not match the :targets
      # option calculated for" — which fires whenever anything else in the tree
      # depends on the same package unrestricted.
      |> Deps.add_dep({:lazy_html, ">= 0.1.0", only: :test})
      # `.formatter.exs` runs `Spark.Formatter` through `import_deps: [:bb]`, and
      # that needs sourceror to parse. Nothing declares it, so without this
      # `mix format` fails the moment a stale copy is cleaned out of `deps/`.
      |> Deps.add_dep({:sourceror, "~> 1.7", runtime: false, targets: :host, only: [:dev, :test]})
    end

    # `mix nerves.new` generates no `runtime.exs`, and the release step says so:
    # "skipping runtime configuration". So this creates the file rather than
    # patching it.
    defp write_runtime_config(igniter) do
      endpoint = Phoenix.web_module(igniter) |> Module.concat(Endpoint)

      Igniter.create_or_update_elixir_file(
        igniter,
        "config/runtime.exs",
        """
        import Config

        #{endpoint_config(igniter, endpoint)}
        """,
        fn zipper ->
          {:ok, Common.add_code(zipper, endpoint_config(igniter, endpoint))}
        end
      )
    end

    defp endpoint_config(igniter, endpoint) do
      app = Application.app_name(igniter)

      """
      # On the board the endpoint serves the drive pad on port 80 and starts
      # itself — there is no `mix phx.server` on a device. `check_origin` is off
      # because the robot is reached by IP, on its own access point as often as
      # not, so there is no origin to check against.
      if config_target() != :host do
        config #{inspect(app)}, #{inspect(endpoint)},
          http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 80],
          server: true,
          check_origin: false
      end
      """
    end

    # `phx.install` writes its live-reload patterns as plain `~r"..."` sigils, and
    # a regex in compile-time configuration has to carry the `E` modifier to
    # survive being written into a release. Without it `mix firmware` fails at
    # the very end with "you must use the /E modifier to store regexes", naming
    # the endpoint rather than the config that produced it.
    #
    # Only a Nerves project builds a release out of `:dev`, which is why this is
    # ours to fix rather than something the installer gets wrong for everyone.
    defp fix_live_reload_patterns(igniter) do
      Igniter.update_file(igniter, "config/dev.exs", fn source ->
        Rewrite.Source.update(source, :content, fn content ->
          Regex.replace(~r/(~r"[^"]*")(?!E)/, content, "\\1E")
        end)
      end)
    end

    defp generate_pages(igniter, robot_module) do
      web_module = Phoenix.web_module(igniter)
      assigns = [web_module: web_module, robot_module: robot_module]

      igniter
      |> copy_page("drive_live", web_module, assigns)
      |> copy_page("wifi_live", web_module, assigns)
      |> add_routes(web_module)
    end

    defp copy_page(igniter, name, web_module, assigns) do
      Igniter.copy_template(
        igniter,
        Path.join(:code.priv_dir(:bb_nsk), "templates/#{name}.ex.eex"),
        # Igniter relocates a module to match its name, so this is where these
        # land whatever is asked for. Naming it directly keeps the two in step.
        Path.join(["lib", Macro.underscore(web_module), "#{name}.ex"]),
        assigns,
        on_exists: :skip
      )
    end

    # The wifi page is the root, because an unconfigured robot is one you have
    # just joined the access point of and the first thing you want is to tell it
    # about a real network. The drive pad is one tap away from there.
    defp add_routes(igniter, web_module) do
      Phoenix.append_to_scope(
        igniter,
        "/",
        """
        live "/", WifiLive
        live "/drive", DriveLive
        """,
        with_pipelines: [:browser],
        arg2: web_module
      )
    end

    # Children terminate in the reverse of the order they start in, so putting
    # the endpoint last means the robot is disarmed and the panel blanked before
    # the thing that was letting anyone watch it goes away.
    defp order_the_endpoint(igniter) do
      Igniter.add_notice(igniter, """
      bb_nsk.add_web: check your application's child order. The endpoint should
      come after the network monitor, the display and the robot — children
      terminate in reverse start order, and a robot nobody can reach is a robot
      nobody can fix.
      """)
    end
  end
else
  defmodule Mix.Tasks.BbNsk.AddWeb do
    @shortdoc "Adds the drive pad, the wifi setup page and the Phoenix they need"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("The bb_nsk.add_web task requires igniter.")
      exit({:shutdown, 1})
    end
  end
end
