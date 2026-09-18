# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.TaskCase do
  @moduledoc """
  A `mix nerves.new`-shaped project for the installer tests to work on.

  `bb_nsk.install` refuses a project with no `:nerves`, and `bb.add_robot` wants
  an application module to wire the robot into, so both are here. Everything
  else a real Nerves project carries — the release, the target config, the
  rootfs overlay — is irrelevant to what these tasks read.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import BB.NSK.TaskCase
      import Igniter.Test
    end
  end

  @doc """
  A project with `:nerves` in its deps and an application module.

  `files` are merged over the defaults rather than replacing them, so a test can
  add a robot module of its own without losing the `mix.exs` that makes the
  project a Nerves one.
  """
  def nerves_project(opts \\ []) do
    Igniter.Test.test_project(
      opts
      |> Keyword.put(:app_name, :my_bot)
      |> Keyword.update(:files, default_files(), &Map.merge(default_files(), &1))
    )
  end

  @doc """
  A project that `bb_nsk.install` has already run against.

  The `add_*` tasks all attach to the topology it establishes, so nearly every
  test of them starts here.
  """
  def installed_project(opts \\ []) do
    opts
    |> nerves_project()
    |> Igniter.compose_task("bb_nsk.install", [])
    |> Igniter.Test.apply_igniter!()
  end

  @doc """
  The content a task left at `path`, whether it created the file or changed one.
  """
  def content(igniter, path) do
    igniter = Igniter.prepare_for_write(igniter)

    case Rewrite.source(igniter.rewrite, path) do
      {:ok, source} -> Rewrite.Source.get(source, :content)
      _ -> ExUnit.Assertions.flunk("#{path} was not created or changed")
    end
  end

  @doc "The robot module's source after a task has run."
  def robot_source(igniter), do: content(igniter, "lib/my_bot/robot.ex")

  defp default_files do
    %{
      "mix.exs" => """
      defmodule MyBot.MixProject do
        use Mix.Project

        def project do
          [app: :my_bot, version: "0.1.0", deps: deps()]
        end

        def application do
          [extra_applications: [:logger], mod: {MyBot.Application, []}]
        end

        defp deps do
          [
            {:nerves, "~> 1.13", runtime: false},
            {:nerves_system_trellis, "~> 0.4", runtime: false, targets: :trellis}
          ]
        end
      end
      """,
      "lib/my_bot/application.ex" => """
      defmodule MyBot.Application do
        @moduledoc false

        use Application

        @impl true
        def start(_type, _args) do
          children = []

          Supervisor.start_link(children, strategy: :one_for_one, name: MyBot.Supervisor)
        end
      end
      """
    }
  end
end
