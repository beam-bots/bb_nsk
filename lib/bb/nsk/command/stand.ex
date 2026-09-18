# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Command.Stand do
  @moduledoc """
  Hands the robot over to the balance controller.

  Issued by `BB.NSK.Balance.Controller` when it sees the robot being held near
  its setpoint and not moving, and available to an operator who wants to engage
  it by hand. It carries no behaviour of its own — the transition *is* the
  point, because a command is the only thing allowed to move the state machine
  and the whole robot watches the state machine.
  """

  use BB.Command

  @impl BB.Command
  def handle_command(_goal, _context, state), do: {:stop, :normal, state}

  @impl BB.Command
  def result(_state), do: {:ok, :balancing, next_state: :balancing}
end
