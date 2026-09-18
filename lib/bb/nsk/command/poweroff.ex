# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Command.Poweroff do
  @moduledoc """
  Shuts the robot down cleanly.

  There is no power button and the panel keeps its last image with no power
  behind it, so without this the choices are an SSH session or pulling the
  battery — and pulling the battery on a robot that is mid-write to its
  application partition is how a configuration goes missing.

  Reachable from the robot dashboard, which lists every command in the DSL, so
  a phone joined to the robot can turn it off.

  ## Only from `:disarmed`

  A robot that is balancing is holding itself up with its wheels, and taking the
  operating system out from under it drops it on the floor. Requiring a disarm
  first costs one tap and makes that somebody's decision rather than a surprise.
  `disarm` is allowed from every state the robot can get stuck in, so there is
  always a way through to here.

  ## It does not wait

  `Nerves.Runtime.poweroff/0` blocks its caller for up to ten minutes and then
  halts the VM, which is a sensible thing for it to do and a terrible thing to
  do inside a command process — the command would never report, and whatever
  asked for it would sit there waiting. So the shutdown is started beside the
  command and the command reports that it was accepted, which is the most
  anything can honestly say about a machine that is switching itself off.
  """

  use BB.Command

  require Logger

  @impl BB.Command
  def handle_command(_goal, _context, state) do
    {:stop, :normal, %{state | result: poweroff(Nerves.Runtime.mix_target())}}
  end

  @impl BB.Command
  def result(%{result: result}), do: result

  # Powering off a laptop because a test asked a robot to would be rude, and on
  # the host there is no robot to power off anyway.
  defp poweroff(:host) do
    Logger.info("Ignoring a poweroff on the host, where there is nothing to switch off.")

    {:error, :host}
  end

  defp poweroff(_target) do
    _shutdown = spawn(&Nerves.Runtime.poweroff/0)

    {:ok, :powering_off}
  end
end
