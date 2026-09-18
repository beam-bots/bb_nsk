# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbNsk.AddWifi do
    @shortdoc "Makes the robot bring up its own network when it has none to join"
    @moduledoc """
    #{@shortdoc}

    A robot that has never been told about a network brings one up itself, named
    after the application and the last four of its serial number. Join it and
    the robot is reachable; tell it about a real network through that, and it
    joins. A mistyped passphrase costs a minute rather than a reflash, because a
    station configuration that never reaches a connection falls back to the
    access point.

    ## One radio, so one mode at a time

    The RTL8723DU advertises both station and access point, but not at once, so
    giving the robot a network of its own **takes the access point away**. That
    is what makes the fallback mandatory rather than a nicety, and it is what
    `BB.NSK.Network.Monitor` is for.

    ## Nothing is stored

    The SSID and passphrase are derived from the OTP application and the board's
    serial number. They survive a reboot without being written anywhere, they
    differ between two robots on the same bench — which matters in a room full
    of them — and they can be recovered from a robot that has forgotten
    everything else.

    The passphrase is a hash rather than the serial's own digits, because the
    serial is printed on things, and it is drawn from an alphabet with no `0`,
    `1`, `i`, `l` or `o` in it, since somebody has to read it off a 400x300
    e-paper panel and type it into a phone. Add the panel with
    `mix bb_nsk.add_display` and it will show it — that is the only place it can
    be read from.

    ## `wlan0` is deliberately left out of the config

    Its configuration is applied at runtime, because the access point is named
    after the serial number and that isn't known until the robot is running.
    `default_config` rather than `config`, so that a saved configuration
    replaces it without the confusion of appearing to ignore the file.

    ## Example

    ```bash
    mix bb_nsk.add_wifi
    mix bb_nsk.add_wifi --regulatory-domain AU
    ```

    ## Options

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    * `--regulatory-domain` - Two-letter country code for the radio (default
      `NZ`). Getting this wrong is a legal matter, not a performance one.
    """

    use Igniter.Mix.Task

    alias Igniter.Project.{Application, Config, Deps}

    @default_domain "NZ"

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        schema: [robot: :string, regulatory_domain: :string],
        aliases: [r: :robot]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      domain = Keyword.get(igniter.args.options, :regulatory_domain, @default_domain)

      igniter
      # Directly rather than through `adds_deps:`, which is for dependencies
      # needed *during* the run and does not reliably reach `mix.exs` from a
      # composed task.
      |> Deps.add_dep({:vintage_net_wifi, "~> 0.12", targets: [:trellis]})
      |> name_the_network()
      |> configure_radio(domain)
      |> add_monitor()
    end

    # `BB.NSK.Network` can't work this out for itself: its own OTP application is
    # `:bb_nsk`, so every robot on the bench would advertise the same name.
    defp name_the_network(igniter) do
      Config.configure(
        igniter,
        "config.exs",
        :bb_nsk,
        [:name],
        to_string(Application.app_name(igniter))
      )
    end

    defp configure_radio(igniter, domain) do
      Config.configure(
        igniter,
        "target.exs",
        :vintage_net,
        [:regulatory_domain],
        domain
      )
    end

    # First of everything, because a robot nobody can reach is a robot nobody can
    # fix. Without it a freshly burned board has no network at all — `wlan0` has
    # no configuration in `config/target.exs` on purpose.
    defp add_monitor(igniter) do
      igniter
      |> Application.add_new_child(BB.NSK.Network.Monitor, before: [:robot])
      |> Igniter.add_notice("""
      bb_nsk.add_wifi: `wlan0` is deliberately absent from config/target.exs —
      BB.NSK.Network.Monitor configures it at runtime, because the access point
      is named after the board's serial number.

      If your target config declares `wlan0` under `config :vintage_net`, remove
      it, or the monitor and the static configuration will fight over the radio.
      """)
    end
  end
else
  defmodule Mix.Tasks.BbNsk.AddWifi do
    @shortdoc "Makes the robot bring up its own network when it has none to join"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("The bb_nsk.add_wifi task requires igniter.")
      exit({:shutdown, 1})
    end
  end
end
