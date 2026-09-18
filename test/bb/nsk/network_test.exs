# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.NetworkTest do
  use ExUnit.Case, async: true

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
end
