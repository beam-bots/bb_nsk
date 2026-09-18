# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Network do
  @moduledoc """
  The robot's own access point, and the credentials for joining somebody else's.

  A robot that has never been told about a network brings one up itself, and
  serves the whole web interface on it. So an unconfigured robot is a robot you
  can drive — join its network, open the address the panel is showing, and the
  drive page is there. Setting it up to join your own network is one page of
  that same interface rather than a separate mode it has to be talked into.

  ## One radio, so one mode at a time

  The RTL8723DU advertises both station and access point, but not at once, so
  giving the robot a network of its own **takes the access point away**. That
  makes a way back mandatory rather than a nicety, which is what
  `BB.NSK.Network.Monitor` is for: a station configuration that never reaches
  a connection falls back to the access point, so a mistyped passphrase costs a
  minute rather than a reflash.

  ## Nothing is stored

  The SSID and the passphrase are derived from the OTP application and the
  board's serial number. They survive a reboot without being written anywhere,
  they differ between two robots on the same bench — which matters in a room
  full of them — and they can be recovered from a robot that has forgotten
  everything else.

  The passphrase is a hash rather than the serial number's own digits, because
  the serial is printed on things. It is drawn from an alphabet with no `0`,
  `1`, `i`, `l` or `o` in it, since somebody has to read it off a 400x300
  e-paper panel and type it into a phone.

  ## Where the credentials live

  `VintageNet` persists what it is told to `/root/vintage_net`, and a persisted
  configuration beats the one compiled into the firmware — so joining a network
  outlives `mix upload`. It does not outlive a `complete` burn, which wipes the
  application partition, so a freshly flashed robot is an access point again.

  The access point itself is applied with `persist: false`. It is the state the
  robot falls back to rather than a state it is ever put into, so persisting it
  would let a bad afternoon become the permanent configuration.
  """

  alias VintageNetWiFi.Cookbook

  # VintageNet is only built for the target. Everything here that names it is
  # callable only there; the parts that make a robot's identity — the SSID, the
  # passphrase, the address — are ordinary arithmetic and work anywhere, which
  # is what lets the panel be previewed and the tests run on the host.
  @compile {:no_warn_undefined, VintageNet}
  @compile {:no_warn_undefined, Cookbook}

  @interface "wlan0"

  # The cookbook's default, and as good as any: high enough in the range to be
  # out of the way of home routers, which cluster at 192.168.0 and 192.168.1.
  @address {192, 168, 24, 1}
  @netmask {255, 255, 255, 0}
  @dhcp_range {{192, 168, 24, 10}, {192, 168, 24, 250}}

  # No 0, 1, i, l or o: the panel draws Spleen at 8x16 and a passphrase is no
  # place to find out whether that is a one or an ell.
  @alphabet ~c"23456789abcdefghjkmnpqrstuvwxyz"
  @passphrase_length 10

  @doc """
  The interface all of this configures.
  """
  @spec interface() :: String.t()
  def interface, do: @interface

  @doc """
  The name of the robot's own network.

  The robot's name, then enough of the serial number to tell two robots apart —
  which a workshop full of them very much needs.

  The name comes from `config :bb_nsk, :name`, which `bb_nsk.add_wifi` sets to
  the host application. It cannot be derived here: this module's own OTP
  application is `:bb_nsk`, so every robot on the bench would advertise the same
  one.
  """
  @spec ssid() :: String.t()
  def ssid, do: "#{name()}-#{serial_suffix()}"

  @doc """
  The passphrase for the robot's own network.

  Derived from the serial number, so it is stable across reboots and different
  on every robot, and shown on the panel because that is the only place anybody
  can read it from.
  """
  @spec passphrase() :: String.t()
  def passphrase do
    :sha256
    |> :crypto.hash(serial())
    |> :binary.bin_to_list()
    |> Enum.take(@passphrase_length)
    |> Enum.map(&Enum.at(@alphabet, rem(&1, length(@alphabet))))
    |> List.to_string()
  end

  @doc """
  Where the robot answers on its own network.
  """
  @spec address() :: :inet.ip4_address()
  def address, do: @address

  @doc """
  The address to open once you have joined the robot's network.
  """
  @spec url() :: String.t()
  def url, do: "http://#{:inet.ntoa(@address)}"

  @doc """
  The configuration for the robot's own access point.
  """
  @spec access_point() :: map
  def access_point do
    {dhcp_start, dhcp_end} = @dhcp_range

    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [
          %{
            mode: :ap,
            ssid: ssid(),
            key_mgmt: :wpa_psk,
            psk: passphrase()
          }
        ]
      },
      ipv4: %{method: :static, address: @address, netmask: @netmask},
      dhcpd: %{start: dhcp_start, end: dhcp_end}
    }
  end

  @doc """
  The configuration for joining somebody else's network.

  An empty passphrase means an open network, which plenty of cafes and a few
  workshops still are.
  """
  @spec station(String.t(), String.t()) :: {:ok, map} | {:error, term}
  def station(ssid, passphrase)

  def station(ssid, empty) when empty in [nil, ""], do: Cookbook.open_wifi(ssid)
  def station(ssid, passphrase), do: Cookbook.wpa_psk(ssid, passphrase)

  @doc """
  Ask the radio to look for networks.

  Results don't come back from this — they arrive asynchronously and are read
  with `access_points/0`.

  **Scanning works while the robot is its own access point**, confirmed on
  hardware 2026-09-17. That is not a given: one radio is doing both jobs, and a
  chip that refused would have been within its rights. Nothing above this
  depends on it anyway — the setup page takes a typed SSID, because a hidden
  network never appears in a scan whatever the radio can do.
  """
  @spec scan() :: :ok | {:error, term}
  def scan do
    if available?(), do: VintageNet.scan(@interface), else: {:error, :unavailable}
  end

  @doc """
  The networks the last scan found, strongest first.
  """
  @spec access_points() :: [map]
  def access_points do
    case available?() && VintageNet.get(["interface", @interface, "wifi", "access_points"]) do
      access_points when is_list(access_points) ->
        access_points
        |> Enum.reject(&(&1.ssid in [nil, ""]))
        |> Enum.uniq_by(& &1.ssid)
        |> Enum.sort_by(& &1.signal_percent, :desc)

      _nothing ->
        []
    end
  end

  @doc """
  Which of the two the robot is currently set up for.

  `:unconfigured` is a robot that has never been told anything, which is the
  state a freshly burned one is in until `BB.NSK.Network.Monitor` brings the
  access point up.

  **A `VintageNetWiFi` interface with no networks counts as unconfigured**, which
  is what it is: an interface that has been declared and never told what to join.
  `mix nerves.new` writes exactly that — `{"wlan0", %{type: VintageNetWiFi}}` —
  into `config/target.exs`, and reading it as `:station` costs a freshly burned
  robot a full connection timeout of doing nothing before it gives up on a
  network it was never told about and brings up its own.
  """
  @spec mode() :: :access_point | :station | :unconfigured
  def mode, do: mode(configuration())

  @doc """
  Which mode a particular `vintage_net` configuration describes.

  Split out from `mode/0` so it can be reasoned about without a radio.
  """
  @spec mode(map | nil) :: :access_point | :station | :unconfigured
  def mode(%{vintage_net_wifi: %{networks: [%{mode: :ap} | _rest]}}), do: :access_point
  def mode(%{vintage_net_wifi: %{networks: [_network | _rest]}}), do: :station
  def mode(_nothing), do: :unconfigured

  @doc """
  Bring up the robot's own access point.

  Deliberately not persisted — see the moduledoc.
  """
  @spec start_access_point() :: :ok | {:error, term}
  def start_access_point do
    if available?(),
      do: VintageNet.configure(@interface, access_point(), persist: false),
      else: {:error, :unavailable}
  end

  @doc """
  Join a network, and remember it.

  The access point goes away as this takes effect, so whoever called this over
  it will lose their connection whether or not the new credentials are any good.
  """
  @spec join(String.t(), String.t()) :: :ok | {:error, term}
  def join(ssid, passphrase) do
    with true <- available?() || {:error, :unavailable},
         {:ok, config} <- station(ssid, passphrase) do
      VintageNet.configure(@interface, config)
    end
  end

  @doc """
  Forget the configured network and return to the access point.
  """
  @spec forget() :: :ok | {:error, term}
  def forget do
    with true <- available?() || {:error, :unavailable},
         :ok <- VintageNet.deconfigure(@interface) do
      start_access_point()
    end
  end

  @doc """
  Whether the interface has reached a network, rather than merely being set up
  for one.
  """
  @spec connected?() :: boolean
  def connected? do
    available?() && VintageNet.get(["interface", @interface, "connection"]) in [:lan, :internet]
  end

  @doc """
  The network the robot is set up to join, or `nil` when it isn't set up for one.
  """
  @spec configured_ssid() :: String.t() | nil
  def configured_ssid do
    case configuration() do
      %{vintage_net_wifi: %{networks: [%{ssid: ssid} | _rest]}} -> ssid
      _nothing -> nil
    end
  end

  defp configuration do
    if available?() and @interface in VintageNet.configured_interfaces() do
      VintageNet.get_configuration(@interface)
    end
  end

  # `vintage_net` only exists on the target, and the setup page is built and
  # looked at on the host, so everything that reaches for it says so rather than
  # raising `UndefinedFunctionError` into a LiveView.
  @doc """
  Whether `vintage_net` is here to be driven.

  False on the host, where the setup page is built and looked at but no radio
  exists, so everything that reaches for it says so rather than raising
  `UndefinedFunctionError` into a LiveView.
  """
  @spec available?() :: boolean
  def available?, do: Code.ensure_loaded?(VintageNet)

  defp name do
    case Application.get_env(:bb_nsk, :name) do
      nil -> "robot"
      name -> to_string(name)
    end
  end

  defp serial_suffix, do: serial() |> String.slice(-4..-1) |> String.downcase()

  defp serial, do: Nerves.Runtime.serial_number()
end
