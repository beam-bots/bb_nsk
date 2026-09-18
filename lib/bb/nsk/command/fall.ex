# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Command.Fall do
  @moduledoc """
  Gives up balancing, leaving the robot waiting to be stood back up.

  Issued by `BB.NSK.Balance.Controller` when the lean goes past the angle it
  can recover from. The controller brakes the wheels itself; this only moves the
  state machine, so that the panel and the NeoPixels — which paint from
  `[:state_machine]` transitions — tell the operator it is safe to pick up.

  It is not a safety transition. The robot stays armed, because it is expected
  to be stood up and carry on, and disarming would mean a fresh arm and its
  prearm checks each time it tipped over.
  """

  use BB.Command

  @impl BB.Command
  def handle_command(_goal, _context, state), do: {:stop, :normal, state}

  @impl BB.Command
  def result(_state), do: {:ok, :fallen, next_state: :fallen}
end
