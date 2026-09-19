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

    ## Where Phoenix comes from

    `bb_nsk.install` adds `phx_install` as a dependency, and this composes the
    five of its subtasks a LiveView dashboard needs. Splitting it that way is
    not tidiness: a package added during an Igniter run is not on the code path
    for that same run to compose, so it has to be in place a task ahead of the
    one that uses it.

    ## Phoenix on a Nerves target is not Phoenix on a server

    Once Phoenix is there, this mounts the `bb_liveview` dashboard and fixes the
    half-dozen places where a board differs from a server:

    - `assets.deploy` is prepended to the `firmware` alias. A Nerves release is
      assembled by `mix firmware`, which has no idea Phoenix is here, so nothing
      else builds `priv/static` and the robot serves a page whose stylesheet
      404s. `esbuild` and `tailwind` are left exactly as `phx.install` declares
      them — `runtime: Mix.env() == :dev`, which is also what `bb_liveview` uses
      — because they have to run *during* a target build and anything narrower
      puts them out of reach of it.
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
    # Not `alias Igniter.Project.Module` — that shadows Elixir's own `Module`,
    # which this needs for `concat/2`.
    alias Igniter.Project.{Application, Config, Deps, TaskAliases}
    alias Igniter.Project.Module, as: ProjectModule
    alias Sourceror.Zipper

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
      it added nothing.

      `mix bb_nsk.install` adds `phx_install`, so this usually means it has not
      been run, or that the dependency was removed. Either way:

          mix deps.get
          mix bb_nsk.add_web

      Reach for `mix igniter.install phx_install` and it will fail instead: its
      orchestrator adds `gettext ~> 0.26` whatever `--no-gettext` says, and `bb`
      reaches `localize`, which wants `~> 1.0`.
      """)
    end

    defp add_web(igniter, robot_module, path) do
      igniter
      |> mount_dashboard(robot_module, path)
      |> add_test_deps()
      |> remove_dns_cluster()
      |> write_runtime_config()
      |> scope_dev_watchers(endpoint_module(igniter))
      |> build_assets_for_firmware()
      |> generate_pages(robot_module)
      |> order_the_endpoint()
    end

    # Nothing else builds them. A Nerves release is assembled by `mix firmware`,
    # which has no idea Phoenix is here, so without this `priv/static` is empty
    # and the robot serves a page whose stylesheet 404s.
    #
    # Two calls rather than one: `:prepend` against a missing alias would set it
    # to just `["assets.deploy"]` and lose the real task, so the base is
    # established first. Both are skipped once `assets.deploy` is in there, which
    # is what makes running this twice safe.
    defp build_assets_for_firmware(igniter) do
      if firmware_builds_assets?(igniter) do
        igniter
      else
        igniter
        |> TaskAliases.add_alias("firmware", ["firmware"])
        |> TaskAliases.add_alias("firmware", ["assets.deploy"], if_exists: :prepend)
      end
    end

    # Looking inside the `firmware` alias specifically. A plain search for
    # "assets.deploy" matches the `"assets.deploy":` alias that `phx.install`
    # defines, which is always there and says nothing about whether a firmware
    # build runs it.
    #
    # Reading rather than rewriting, so a heuristic costs at worst a duplicated
    # entry on a second run rather than broken code.
    defp firmware_builds_assets?(igniter) do
      igniter
      |> Igniter.include_existing_file("mix.exs")
      |> Map.fetch!(:rewrite)
      |> Rewrite.source!("mix.exs")
      |> Rewrite.Source.get(:content)
      |> String.match?(~r/firmware:\s*\[[^\]]*"assets\.deploy"/)
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
      |> Deps.add_dep({:sourceror, "~> 1.7", runtime: false, only: [:dev, :test]})
    end

    # `mix nerves.new` generates no `runtime.exs`, and the release step says so:
    # "skipping runtime configuration". So this creates the file rather than
    # patching it.
    defp endpoint_module(igniter) do
      igniter |> Phoenix.web_module() |> Module.concat(Endpoint)
    end

    defp write_runtime_config(igniter) do
      endpoint = endpoint_module(igniter)

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

    # `phx.install` configures asset watchers and live reload in `config/dev.exs`
    # with nothing to say they are for a developer's machine. A Nerves firmware
    # is built out of `:dev` by default, so on a board the endpoint starts and
    # goes looking for `esbuild` and `tailwind` executables that were never
    # cross-compiled and would be no use if they had been.
    #
    # `Mix.target/0`, not `config_target/0`. This file is build-time config, and
    # `config_target/0` belongs to runtime configuration — used here it raises
    # "no :target key was given to this configuration file" the moment anything
    # evaluates `config.exs`, which imports this.
    #
    # And not `config_env/0` either: that answers `:dev`, `:test` or `:prod` and
    # never `:host`, so a guard written on it reads correctly and is always
    # false. That mistake is why the prototype's watchers never ran at all.
    #
    # Guarding live reload here also settles the `E` modifier: a regex only has
    # to survive being written into a release if it is evaluated during a release
    # build, and inside this guard it is not.
    defp scope_dev_watchers(igniter, endpoint) do
      app = Application.app_name(igniter)

      igniter
      |> Config.configure("dev.exs", app, [endpoint, :watchers], [])
      |> Config.configure("dev.exs", app, [endpoint, :live_reload], [])
      |> Igniter.update_elixir_file("config/dev.exs", fn zipper ->
        {:ok, Common.add_code(zipper, host_only_dev_config(app, endpoint))}
      end)
    end

    defp host_only_dev_config(app, endpoint) do
      """
      # Only on a developer's machine. A Nerves firmware is built out of `:dev`,
      # and a board has no asset toolchain to run and no source tree to watch.
      if Mix.target() == :host do
        config #{inspect(app)}, #{inspect(endpoint)},
          watchers: [
            esbuild: {Esbuild, :install_and_run, [#{inspect(app)}, ["--sourcemap=inline", "--watch"]]},
            tailwind: {Tailwind, :install_and_run, [#{inspect(app)}, ["--watch"]]}
          ],
          live_reload: [
            web_console_logger: true,
            patterns: [
              ~r"priv/static/(?!uploads/).*\\.(js|css|png|jpeg|jpg|gif|svg)$"E,
              ~r"lib/.*_web/router\\.ex$"E,
              ~r"lib/.*_web/(controllers|live|components)/.*\\.(ex|heex)$"E
            ]
          ]
      end
      """
    end

    # A robot is one node on a network it usually made itself. Clustering over
    # DNS is for a fleet behind a service discovery record, and `phx.install`
    # adds it to every project regardless.
    defp remove_dns_cluster(igniter) do
      igniter
      |> Deps.remove_dep(:dns_cluster)
      |> remove_dns_cluster_child()
      |> remove_dns_cluster_config()
    end

    defp remove_dns_cluster_child(igniter) do
      ProjectModule.find_and_update_module!(
        igniter,
        Application.app_module(igniter),
        &drop_dns_cluster_child/1
      )
    end

    defp remove_dns_cluster_config(igniter) do
      Igniter.update_elixir_file(igniter, "config/runtime.exs", fn zipper ->
        {:ok, remove_node(zipper, &dns_cluster_query?/1)}
      end)
    end

    defp supervised_dns_cluster?({:{}, _meta, [{:__aliases__, _, [:DNSCluster]} | _]}), do: true
    defp supervised_dns_cluster?({{:__aliases__, _, [:DNSCluster]}, _opts}), do: true
    defp supervised_dns_cluster?(_node), do: false

    defp dns_cluster_query?({:config, _meta, [_app, {:__block__, _, [:dns_cluster_query]} | _]}) do
      true
    end

    defp dns_cluster_query?(_node), do: false

    defp remove_node(zipper, predicate) do
      case Zipper.find(zipper, predicate) do
        nil -> zipper
        found -> found |> Zipper.remove() |> Zipper.top()
      end
    end

    # The list is rebuilt without the child rather than the child being removed
    # from it. `Zipper.remove/1` leaves a `nil` literal where a list element was
    # — as does `Igniter.Code.List.remove_from_list/2`, which is built on it —
    # and a supervisor handed a `nil` child refuses to start, so the application
    # does not boot and the board never reaches the network.
    #
    # Removing a *statement* from a block is fine, which is why the runtime
    # configuration above can use `remove_node/2`.
    #
    # `mix nerves.new` writes `children = [...] ++ target_children()`, so the list
    # is the left side of the `++` rather than the whole right-hand side.
    # Rebuilds the children list without the child, rather than removing the
    # child from it. `Zipper.remove/1` leaves a `nil` literal where a list element
    # was — as does `Igniter.Code.List.remove_from_list/2`, which is built on it —
    # and a supervisor handed a `nil` child refuses to start, so the application
    # never boots and the board never reaches the network. Removing a *statement*
    # from a block is fine, which is why the runtime configuration can use
    # `remove_node/2`.
    #
    # Climbing to the enclosing list rather than taking `Zipper.up/1` once: a
    # two-element tuple is itself traversed as a list of its two children, so the
    # first list above a `{DNSCluster, opts}` child is the tuple's own insides.
    # The one we want is the nearest list that *contains* a match.
    defp drop_dns_cluster_child(zipper) do
      with found when not is_nil(found) <- Zipper.find(zipper, &supervised_dns_cluster?/1),
           {:ok, list} <- climb_to_containing_list(found, &supervised_dns_cluster?/1) do
        {:ok, list |> reject_from_list(&supervised_dns_cluster?/1) |> Zipper.top()}
      else
        # Already gone, which is the expected case on a second run.
        _nothing_to_do -> {:ok, zipper}
      end
    end

    defp climb_to_containing_list(zipper, predicate) do
      if zipper |> Zipper.node() |> list_contents() |> Enum.any?(&matches?(&1, predicate)) do
        {:ok, zipper}
      else
        case Zipper.up(zipper) do
          nil -> :error
          up -> climb_to_containing_list(up, predicate)
        end
      end
    end

    defp reject_from_list(zipper, predicate) do
      case Zipper.node(zipper) do
        {:__block__, meta, [list]} when is_list(list) ->
          Zipper.replace(zipper, {:__block__, meta, [reject(list, predicate)]})

        list when is_list(list) ->
          Zipper.replace(zipper, reject(list, predicate))

        _not_a_list ->
          zipper
      end
    end

    defp reject(list, predicate), do: Enum.reject(list, &matches?(&1, predicate))

    # Sourceror's literal encoder wraps each element of a list in a `__block__`,
    # so a predicate written against the node it encloses never matches one.
    defp matches?(element, predicate), do: predicate.(unwrap(element))

    defp unwrap({:__block__, _meta, [inner]}), do: inner
    defp unwrap(node), do: node

    defp list_contents({:__block__, _meta, [list]}) when is_list(list), do: list
    defp list_contents(list) when is_list(list), do: list
    defp list_contents(_not_a_list), do: []

    defp generate_pages(igniter, robot_module) do
      web_module = Phoenix.web_module(igniter)
      assigns = [web_module: web_module, robot_module: robot_module]

      igniter
      |> copy_page("drive_live", web_module, assigns)
      |> copy_page("wifi_live", web_module, assigns)
      |> add_routes(web_module)
    end

    # Skipping on the module rather than on the path. Igniter's Phoenix extension
    # relocates a LiveView into `live/` after it is created, so the path asked for
    # here is not where it ends up — and an `on_exists: :skip` against the
    # original path sees nothing on a second run and writes the page a second
    # time, under a name the first one already has.
    defp copy_page(igniter, name, web_module, assigns) do
      module = Module.concat(web_module, Macro.camelize(name))

      case ProjectModule.module_exists(igniter, module) do
        {true, igniter} ->
          igniter

        {false, igniter} ->
          Igniter.copy_template(
            igniter,
            Path.join(:code.priv_dir(:bb_nsk), "templates/#{name}.ex.eex"),
            Path.join(["lib", Macro.underscore(web_module), "#{name}.ex"]),
            assigns,
            on_exists: :skip
          )
      end
    end

    # The wifi page is the root, because an unconfigured robot is one you have
    # just joined the access point of and the first thing you want is to tell it
    # about a real network. The drive pad is one tap away from there.
    # Neither of these is idempotent on its own. `bb_liveview.install` appends its
    # dashboard scope every time it runs, and a second `live_session` of the same
    # name is a compile error — "attempting to redefine live_session"; appending
    # the pages twice gives duplicate routes. `bb_nsk.cheat` is meant to be safe
    # to run over a project that is already half built, so both are guarded on
    # what is already in the router.
    defp mount_dashboard(igniter, robot_module, path) do
      if router_mentions?(igniter, "bb_dashboard") do
        igniter
      else
        Igniter.compose_task(igniter, "bb_liveview.install", [
          "--robot",
          inspect(robot_module),
          "--path",
          path
        ])
      end
    end

    defp add_routes(igniter, web_module) do
      if router_mentions?(igniter, "DriveLive") do
        igniter
      else
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
    end

    defp router_mentions?(igniter, text) do
      with {_igniter, router} when not is_nil(router) <- Phoenix.select_router(igniter),
           {:ok, {_igniter, _source, zipper}} <- ProjectModule.find_module(igniter, router) do
        zipper
        |> Zipper.topmost()
        |> Zipper.node()
        |> Sourceror.to_string()
        |> String.contains?(text)
      else
        _no_router -> false
      end
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
