# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Network.Monitor do
  @moduledoc """
  Decides whether the robot is an access point or a station, and notices when
  being a station hasn't worked.

  Two jobs, both of which only matter at the edges:

  **At boot, a robot with no configuration becomes an access point.** Nothing in
  `config/target.exs` configures `wlan0`, because the SSID carries the board's
  serial number and that isn't known until the thing is running. So an
  unconfigured interface is the normal state of a freshly burned robot, and this
  is what turns it into a network somebody can join.

  **A station that never connects falls back.** Wrong passphrase, network
  renamed, robot taken somewhere else — from here they all look the same, which
  is a configured interface that never reports `:lan` or `:internet`. After
  `:connect_timeout` it brings the access point back so the robot can be told
  again.

  The fallback is not persisted, so a reboot tries the configured network once
  more. That is deliberate: a robot carried out of range of its network should
  be an access point while it is away and rejoin when it comes home, without
  anybody having to set it up twice.

  ## What it deliberately doesn't do

  It doesn't keep retrying in the background once it has fallen back. The radio
  can't be both at once, so a retry would take the access point away from
  whoever is in the middle of using it — which is precisely the person who is
  trying to fix the problem.
  """

  use GenServer

  alias BB.NSK.Network

  # Only built for the target, where this process runs.
  @compile {:no_warn_undefined, VintageNet}

  require Logger

  @default_connect_timeout :timer.seconds(60)

  @doc """
  Start the monitor.

  ## Options

  - `:connect_timeout` - how long a configured network has to reach a
    connection before the access point comes back, in milliseconds
  - `:name` - registered name, default `#{inspect(__MODULE__)}`
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)

    VintageNet.subscribe(["interface", Network.interface(), "connection"])

    {:ok, %{timeout: timeout, timer: nil}, {:continue, :decide}}
  end

  @impl GenServer
  def handle_continue(:decide, state), do: {:noreply, decide(Network.mode(), state)}

  @impl GenServer
  def handle_info({VintageNet, _property, _old, connection, _meta}, state)
      when connection in [:lan, :internet] do
    {:noreply, cancel(state)}
  end

  def handle_info({VintageNet, _property, _old, _connection, _meta}, state), do: {:noreply, state}

  def handle_info(:connect_timeout, state) do
    Logger.warning(
      "#{Network.interface()} never reached a network, so falling back to the access point. " <>
        "The configured network is still remembered and will be tried again on the next boot."
    )

    start_access_point()

    {:noreply, %{state | timer: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Never configured, so there is nothing to fall back from — be the access
  # point and don't arm anything.
  defp decide(:unconfigured, state) do
    Logger.info("#{Network.interface()} has no configuration, so bringing up the access point.")

    start_access_point()

    state
  end

  defp decide(:access_point, state), do: state

  # Already connected by the time we got here, which happens on a warm restart.
  defp decide(:station, state) do
    if Network.connected?(), do: state, else: arm(state)
  end

  defp arm(state) do
    %{state | timer: Process.send_after(self(), :connect_timeout, state.timeout)}
  end

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(state) do
    Process.cancel_timer(state.timer)

    %{state | timer: nil}
  end

  defp start_access_point do
    case Network.start_access_point() do
      :ok ->
        Logger.info(
          "Access point #{Network.ssid()} is up. Join it and open #{Network.url()} — the " <>
            "passphrase is on the panel."
        )

      {:error, reason} ->
        Logger.error("Could not bring up the access point: #{inspect(reason)}")
    end
  end
end
