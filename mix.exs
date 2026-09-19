# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.MixProject do
  use Mix.Project

  @moduledoc """
  Beam Bots board support for the Nerves Starter Kit and its Balance Bot add-on.
  """

  @version "0.1.0"

  def project do
    [
      aliases: aliases(),
      app: :bb_nsk,
      consolidate_protocols: Mix.env() == :prod,
      deps: deps(),
      description: @moduledoc,
      dialyzer: dialyzer(),
      docs: docs(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      start_permanent: Mix.env() == :prod,
      version: @version
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp aliases, do: []

  defp dialyzer do
    [
      # `vintage_net` and its wifi technology are `runtime: false`, which keeps
      # them out of the PLT along with their types. Naming them here puts the
      # types back without starting anything.
      # `:ex_unit` because CI runs dialyzer under `MIX_ENV=test`, which compiles
      # `test/support` — and the case template in there is the only thing in the
      # package that touches ExUnit.
      plt_add_apps: [:ex_unit, :mix, :vintage_net, :vintage_net_wifi],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/logo.png",
      extras:
        ["README.md", "CHANGELOG.md"]
        |> Enum.concat(Path.wildcard("documentation/**/*.{md,livemd,cheatmd}")),
      groups_for_extras: [
        "How-to Guides": ~r/how-to\//
      ],
      source_ref: "main",
      source_url: "https://github.com/beam-bots/bb_nsk"
    ]
  end

  defp package do
    [
      maintainers: ["James Harton <james@harton.nz>"],
      licenses: ["Apache-2.0"],
      links: %{
        "Source" => "https://github.com/beam-bots/bb_nsk",
        "Sponsor" => "https://github.com/sponsors/jimsynz"
      }
    ]
  end

  defp bb_dep(default, package \\ :bb) do
    case System.get_env("BB_VERSION") do
      nil -> default
      "local" -> [path: "../#{package}", override: true]
      "main" -> [git: "https://github.com/beam-bots/#{package}.git", override: true]
      version -> "~> #{version}"
    end
  end

  defp deps do
    [
      {:bb, bb_dep("~> 0.31")},
      {:bb_estimator_ahrs, bb_dep("~> 0.2 and >= 0.2.2", :bb_estimator_ahrs)},
      # A real dependency rather than something `add_web` installs, for the same
      # reason as the parameter store: a package added during a run is not on the
      # code path for `compose_task/2` to reach, and neither `adds_deps:` nor
      # `installs:` changes that from a composed task.
      #
      # It earns its place anyway. An unconfigured robot comes up as its own
      # access point serving the drive page, and that page is how it is told
      # about a real network — so on this robot the web interface is the way in,
      # not an extra.
      {:bb_liveview, bb_dep("~> 0.3", :bb_liveview)},
      {:bb_parameter_store_cubdb, bb_dep("~> 0.1", :bb_parameter_store_cubdb)},
      {:bb_sensor_bmi323, bb_dep("~> 0.1 and >= 0.1.4", :bb_sensor_bmi323)},

      # Hardware access. Optional so that a project which uses only some of this
      # package's subsystems isn't made to carry the rest — the installers add
      # whichever are needed to the consumer's `mix.exs`.
      {:circuits_gpio, "~> 2.1", optional: true},
      {:circuits_i2c, "~> 2.1", optional: true},
      # `BB.NSK.Command.Poweroff` asks it to bring the board down, and the doctor
      # task reads `fit_config` out of its KV store.
      {:nerves_runtime, "~> 0.13", optional: true},

      # The panel's renderer. Optional because a robot that only balances should
      # not carry a Skia NIF, and `optional: true` still puts it in the
      # dependency graph — so where a consumer does have it, it is compiled
      # before this package and the `Code.ensure_loaded?` guards see it.
      {:emerge, "== 0.4.0-beta.1", optional: true},
      {:video_interop, "~> 0.1.1", optional: true},

      # `BB.NSK.Network` drives these directly. Optional because a robot that
      # never runs `bb_nsk.add_wifi` has no use for them, and because they only
      # mean anything on the target — but naming them gives dialyzer the types
      # rather than a page of `unknown_function`.
      #
      # `runtime: false` because `vintage_net` takes over `/etc/resolv.conf` when
      # it starts, which on a developer's laptop it cannot write and should not
      # want to. Nothing here starts it; a robot that declares the wifi monitor
      # gets it from its own dependency.
      {:vintage_net, "~> 0.13", optional: true, runtime: false},
      {:vintage_net_wifi, "~> 0.12", optional: true, runtime: false},

      # dev/test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.0", only: [:dev, :test], runtime: false},
      # Tracks bb_liveview's constraint so consumers depending on both don't see
      # a diverged-dependencies error.
      {:igniter, "~> 0.7 and >= 0.7.3", only: [:dev, :test], runtime: false},
      {:mimic, "~> 2.0", only: :test},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      # `bb_nsk.add_web` composes `bb_liveview.install`, which composes the five
      # `phx.install.*` subtasks that put Phoenix into a project that has none.
      # `bb_liveview` declares `phx_install` via `adds_deps:`, which fetches it
      # without putting its tasks on the code path — so it has to be a real
      # dependency of something, and dev/test is the right scope for a code
      # generator that never ships in firmware.
      {:phx_install, "~> 0.1", only: [:dev, :test], runtime: false}
    ]
  end

  # Test support only under `:test`. It carries an `ExUnit.CaseTemplate` and
  # reaches into `Igniter.Test`, neither of which means anything in `:dev` —
  # compiling it there gives dialyzer a pile of unknown functions to report.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
