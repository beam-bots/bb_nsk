# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Status do
  @moduledoc """
  A snapshot of what the robot and the board it runs on are currently doing.

  Gathering the values is separated from drawing them so that
  `BB.NSK.Display.Dashboard` stays pure and can be previewed from the host.

  `temperature_c` and `humidity_percent` come from `BB.NSK.Sensor.Environment`
  rather than from `snapshot/1`, because they arrive as messages rather than
  being there to be read. Whoever is drawing the status fills them in.

  `access_point_passphrase` is set only while the robot is running its own
  network, because that is the only time anybody needs it. It is derived from
  the board's serial number rather than stored, so the panel is the one place it
  can be read from — see `BB.NSK.Network`.

  Every field is nillable: some of it is genuinely unavailable. There is no
  battery telemetry on this board at all — no PMIC or fuel gauge, and `gpadc` is
  disabled in the device tree — so `battery_percent` is always `nil` until an
  INA219 or similar is fitted to one of the live I2C buses.
  """

  # VintageNet is only built for the target, so the network fields come back nil
  # when a snapshot is taken on the host.
  alias BB.NSK.Network
  alias Nerves.Runtime.KV

  @compile {:no_warn_undefined, VintageNet}

  @wlan "wlan0"

  defstruct [
    :battery_percent,
    :access_point_passphrase,
    :connection,
    :firmware_valid?,
    :firmware_version,
    :hostname,
    :humidity_percent,
    :ip,
    :load_average,
    :memory_percent,
    :operational_state,
    :safety_state,
    :signal_percent,
    :ssid,
    :temperature_c,
    :uptime_ms
  ]

  @type t :: %__MODULE__{
          battery_percent: 0..100 | nil,
          access_point_passphrase: String.t() | nil,
          connection: :internet | :lan | :disconnected | nil,
          firmware_valid?: boolean | nil,
          firmware_version: String.t() | nil,
          hostname: String.t() | nil,
          humidity_percent: float | nil,
          ip: String.t() | nil,
          load_average: float | nil,
          memory_percent: 0..100 | nil,
          operational_state: atom | nil,
          safety_state: atom | nil,
          signal_percent: 0..100 | nil,
          ssid: String.t() | nil,
          temperature_c: float | nil,
          uptime_ms: non_neg_integer | nil
        }

  @doc """
  Take a snapshot of the robot and the system.
  """
  @spec snapshot(module) :: t
  def snapshot(robot) do
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)

    %__MODULE__{
      firmware_valid?: Nerves.Runtime.firmware_valid?(),
      firmware_version: KV.get_active("nerves_fw_version"),
      hostname: hostname(),
      load_average: load_average(),
      memory_percent: memory_percent(),
      operational_state: BB.Robot.Runtime.operational_state(robot),
      safety_state: BB.Safety.state(robot),
      uptime_ms: uptime_ms
    }
    |> put_access_point()
    |> put_network()
  end

  # Only while the robot is its own access point, because that is the only time
  # anybody needs it and a passphrase left on a screen is a passphrase on a
  # screen. It is derived rather than stored, so this is the one place it can be
  # read from — see `BB.NSK.Network`.
  defp put_access_point(status) do
    case Network.mode() do
      :access_point -> %{status | access_point_passphrase: Network.passphrase()}
      _joined_or_starting -> status
    end
  end

  defp put_network(status) do
    case Code.ensure_loaded?(VintageNet) do
      true ->
        {ssid, signal_percent} = wifi()

        %{
          status
          | connection: VintageNet.get(["interface", @wlan, "connection"]),
            ip: ipv4_address(),
            signal_percent: signal_percent,
            ssid: ssid
        }

      false ->
        status
    end
  end

  @doc """
  Pick the signal strength for `ssid` out of a list of access points.

  Nothing in the property table says which access point we are associated with,
  and one network is often served by several — a mesh or a set of repeaters all
  advertising the same SSID at different strengths. wpa_supplicant associates
  with the strongest, so that is the one reported here.

  Returns `nil` when the SSID is unknown or isn't among the access points, which
  is the normal case for a hidden network: those advertise a blank SSID.
  """
  @spec signal_percent(String.t() | nil, [map] | term) :: 0..100 | nil
  def signal_percent(nil, _access_points), do: nil

  def signal_percent(ssid, access_points) when is_list(access_points) do
    access_points
    |> Enum.filter(&match?(%{ssid: ^ssid}, &1))
    |> Enum.map(& &1.signal_percent)
    |> case do
      [] -> nil
      strengths -> Enum.max(strengths)
    end
  end

  def signal_percent(_ssid, _access_points), do: nil

  defp wifi do
    ssid = associated_ssid()

    {ssid, signal_percent(ssid, VintageNet.get(["interface", @wlan, "wifi", "access_points"]))}
  end

  # wpa_supplicant only publishes `wifi.current_ap` for connections it
  # recognises, and on this board it never appears at all, so fall back to the
  # SSID the interface is configured to join.
  defp associated_ssid do
    case VintageNet.get(["interface", @wlan, "wifi", "current_ap"]) do
      %{ssid: ssid} when is_binary(ssid) and ssid != "" -> ssid
      _unknown -> configured_ssid()
    end
  end

  defp configured_ssid do
    case VintageNet.get(["interface", @wlan, "config"]) do
      %{vintage_net_wifi: %{networks: [%{ssid: ssid} | _others]}} -> ssid
      _unconfigured -> nil
    end
  end

  defp ipv4_address do
    case VintageNet.get(["interface", @wlan, "addresses"]) do
      addresses when is_list(addresses) -> Enum.find_value(addresses, &routable_ipv4/1)
      _unconfigured -> nil
    end
  end

  defp routable_ipv4(%{family: :inet, scope: :universe, address: address}),
    do: address |> :inet.ntoa() |> to_string()

  defp routable_ipv4(_address), do: nil

  # `:inet.gethostname/0` has no failure case — it reads what the node was
  # started with — so there is nothing to fall back to.
  defp hostname do
    {:ok, hostname} = :inet.gethostname()

    to_string(hostname)
  end

  defp memory_percent do
    with {:ok, contents} <- File.read("/proc/meminfo"),
         %{"MemTotal" => total, "MemAvailable" => available} <- parse_meminfo(contents) do
      round((total - available) / total * 100)
    else
      _unavailable -> nil
    end
  end

  defp parse_meminfo(contents) do
    ~r/^(MemTotal|MemAvailable):\s+(\d+) kB$/m
    |> Regex.scan(contents)
    |> Map.new(fn [_line, key, value] -> {key, String.to_integer(value)} end)
  end

  defp load_average do
    with {:ok, contents} <- File.read("/proc/loadavg"),
         {load, _rest} <- Float.parse(contents) do
      load
    else
      _unavailable -> nil
    end
  end
end
