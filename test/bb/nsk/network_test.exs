# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.NetworkTest do
  # `BB.NSK.name/0` reads application configuration, which is global.
  use ExUnit.Case, async: false

  alias BB.NSK.Display
  alias BB.NSK.Network

  describe "mode/1" do
    test "a robot that has been told nothing is unconfigured" do
      assert Network.mode(nil) == :unconfigured
      assert Network.mode(%{}) == :unconfigured
    end

    # What `mix nerves.new` writes into `config/target.exs`. Reading it as
    # `:station` cost a freshly burned robot a full connection timeout of sitting
    # there before it gave up on a network it had never been told about — which
    # is exactly the minute somebody spends wondering whether the board is dead.
    test "a wifi interface with nothing to join is unconfigured, not a station" do
      assert Network.mode(%{type: VintageNetWiFi}) == :unconfigured

      assert Network.mode(%{type: VintageNetWiFi, vintage_net_wifi: %{networks: []}}) ==
               :unconfigured
    end

    test "a network to join makes it a station" do
      configuration = %{
        type: VintageNetWiFi,
        vintage_net_wifi: %{networks: [%{ssid: "somewhere", mode: :infrastructure}]}
      }

      assert Network.mode(configuration) == :station
    end

    test "its own network is the access point" do
      configuration = %{
        type: VintageNetWiFi,
        vintage_net_wifi: %{networks: [%{ssid: "robot-abcd", mode: :ap}]}
      }

      assert Network.mode(configuration) == :access_point
    end
  end

  describe "the robot's name" do
    setup do
      previous = Application.get_env(:bb_nsk, :name)
      on_exit(fn -> Application.put_env(:bb_nsk, :name, previous) end)
    end

    # It cannot be derived: this package's own OTP application is `:bb_nsk`, so a
    # robot asking its libraries what it is called gets `bb_nsk` back — which put
    # `BB_NSK` across the top of a panel and would have had every robot on a
    # bench advertising the same access point.
    test "comes from configuration, not from this package" do
      Application.put_env(:bb_nsk, :name, :eunice)

      assert BB.NSK.name() == "eunice"
      assert Display.name() == "EUNICE"
      assert Network.ssid() =~ "eunice-"
    end

    test "falls back to something neutral rather than this package's name" do
      Application.delete_env(:bb_nsk, :name)

      assert BB.NSK.name() == "robot"
      refute BB.NSK.name() =~ "bb_nsk"
    end
  end
end
