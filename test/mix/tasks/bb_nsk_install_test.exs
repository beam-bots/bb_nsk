# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.BbNsk.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # `bb_nsk.install` refuses a project with no `:nerves`, so every test needs one
  # that has it. The rest of a `mix nerves.new` project doesn't matter here —
  # what the installer reads is the dependency list.
  defp nerves_project(opts \\ []) do
    files = %{
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

    test_project(
      opts
      |> Keyword.put(:app_name, :my_bot)
      |> Keyword.update(:files, files, &Map.merge(files, &1))
    )
  end

  describe "preconditions" do
    # Igniter is not the right tool for scaffolding a Nerves project, and a
    # project without one would fail much later and much less clearly.
    test "refuses a project that isn't a Nerves project" do
      assert_raise Mix.Error, ~r/mix nerves\.new/, fn ->
        test_project(app_name: :my_bot)
        |> Igniter.compose_task("bb_nsk.install", [])
      end
    end
  end

  describe "the device tree" do
    setup do
      %{igniter: Igniter.compose_task(nerves_project(), "bb_nsk.install", [])}
    end

    # Without this a freshly burned board boots the base Nerves Starter Kit tree
    # and reaches none of the add-on hardware — no motor PWM, no IMU bus, no
    # NeoPixels.
    test "writes provisioning that selects nsk-balance-bot", %{igniter: igniter} do
      igniter
      |> assert_creates("config/provisioning.conf")
      |> assert_has_content("config/provisioning.conf", ~r/fit_config", "nsk-balance-bot/)
    end

    # The serial number line comes from the system's own provisioning file, and
    # this one replaces that file rather than adding to it — so dropping the line
    # would leave every board unserialised.
    test "carries the serial number provisioning across", %{igniter: igniter} do
      assert_has_content(igniter, "config/provisioning.conf", ~r/nerves_serial_number/)
    end

    test "points nerves at the provisioning file", %{igniter: igniter} do
      assert_has_content(igniter, "config/config.exs", "provisioning")
    end

    # `mix nerves.new --target trellis` pins ~> 0.4, and 0.5.0 is the first
    # release whose FIT image carries the balance bot device tree at all.
    test "bumps nerves_system_trellis past the version that can't boot it", %{igniter: igniter} do
      assert_has_content(igniter, "mix.exs", ~r/nerves_system_trellis, "~> 0\.5"/)
    end
  end

  describe "the robot module" do
    setup do
      %{igniter: Igniter.compose_task(nerves_project(), "bb_nsk.install", [])}
    end

    # The standing topology is the thing every later task attaches to: the body
    # reaches the world through the two joints it is free to move in.
    test "creates a robot with the standing topology", %{igniter: igniter} do
      for entity <- ["link :world", "joint :ground", "link :ground_contact", "joint :lean"] do
        assert_has_content(igniter, "lib/my_bot/robot.ex", entity)
      end
    end

    test "gives base_link the measured geometry", %{igniter: igniter} do
      igniter
      |> assert_has_content("lib/my_bot/robot.ex", "link :base_link")
      |> assert_has_content("lib/my_bot/robot.ex", "mass(@body_mass)")
    end

    # No hardware — that is what the add_* tasks are for, and a workshop needs
    # each of them to be a visible step rather than a fait accompli.
    test "adds no wheels, no IMU and no balance loop", %{igniter: igniter} do
      refute_has_content(igniter, "lib/my_bot/robot.ex", "BB.NSK.Wheel")
      refute_has_content(igniter, "lib/my_bot/robot.ex", "BB.Sensor.BMI323")
      refute_has_content(igniter, "lib/my_bot/robot.ex", "BB.NSK.Balance")
    end

    test "honours --robot", _context do
      nerves_project()
      |> Igniter.compose_task("bb_nsk.install", ["--robot", "MyBot.Wheelie"])
      |> assert_has_content("lib/my_bot/wheelie.ex", "defmodule MyBot.Wheelie")
    end

    # A robot the user has already written is theirs. The installer still wires
    # the supervision tree and the provisioning around it.
    test "leaves an existing robot module alone" do
      nerves_project(
        files: %{
          "lib/my_bot/robot.ex" => """
          defmodule MyBot.Robot do
            use BB

            topology do
              link :base_link do
              end
            end
          end
          """
        }
      )
      |> Igniter.compose_task("bb_nsk.install", [])
      |> refute_has_content("lib/my_bot/robot.ex", "link :world")
    end
  end

  defp assert_has_content(igniter, path, %Regex{} = pattern) do
    assert content(igniter, path) =~ pattern
    igniter
  end

  defp assert_has_content(igniter, path, string) when is_binary(string) do
    assert content(igniter, path) =~ string
    igniter
  end

  defp refute_has_content(igniter, path, string) do
    refute content(igniter, path) =~ string
    igniter
  end

  defp content(igniter, path) do
    igniter = Igniter.prepare_for_write(igniter)

    case Rewrite.source(igniter.rewrite, path) do
      {:ok, source} -> Rewrite.Source.get(source, :content)
      _ -> flunk("#{path} was not created or changed")
    end
  end
end
