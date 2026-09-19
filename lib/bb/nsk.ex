# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK do
  @moduledoc """
  Board support for the Nerves Starter Kit and its Beam Bots Balance Bot add-on.

  See `Mix.Tasks.BbNsk.Install` for getting a robot built out of it.
  """

  @default_name "robot"

  @doc """
  What the robot calls itself.

  Set by `bb_nsk.install` to the host application, and used anywhere a robot has
  to introduce itself: the heading on the panel, and the name of the access point
  it brings up when it has no network to join.

  It cannot be derived. This package's own OTP application is `:bb_nsk`, so a
  robot asking its libraries what it is called gets the library's name back —
  which is how a board ended up with `BB_NSK` across the top of its screen, and
  how every robot on a bench would have advertised the same access point.
  """
  @spec name() :: String.t()
  def name do
    case Application.get_env(:bb_nsk, :name) do
      nil -> @default_name
      name -> to_string(name)
    end
  end
end
