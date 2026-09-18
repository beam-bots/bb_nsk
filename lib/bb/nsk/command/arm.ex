# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Command.Arm do
  @moduledoc """
  Arms the robot, and lands it in the state its attitude calls for.

  `BB.Command.Arm` transitions to the robot's configured initial state, which is
  `:idle` — right for a robot with an arm to move, wrong for one that is either
  already balancing or already on its side. Arming a fallen robot into `:idle`
  left it looking, from the NeoPixels, exactly like one standing ready to go.

  So it asks `BB.NSK.Balance.Controller` where it ought to be. The controller is
  the only thing that knows: it has the last lean the IMU reported and the trim
  it has wound on since boot, neither of which is a parameter anyone else could
  read. If there is no controller — on the host, there isn't — it says `:idle`,
  which is the honest answer for a robot whose attitude nothing has measured.

  Deciding here rather than letting the loop reclassify on its next sample means
  there is no window in which the robot is armed and calling itself something it
  isn't. That window was 10 ms, which does not sound like much until the thing
  looking at it is a person deciding whether to let go.
  """

  use BB.Command

  alias BB.NSK.Balance.Controller, as: Balance
  alias BB.Safety.Controller

  @impl BB.Command
  def handle_command(_goal, context, state) do
    case Controller.arm(context.robot_module) do
      :ok ->
        {:stop, :normal,
         %{
           state
           | result: {:ok, :armed},
             next_state: Balance.classify(context.robot_module)
         }}

      {:error, reason} ->
        {:stop, :normal, %{state | result: {:error, reason}}}
    end
  end

  @impl BB.Command
  def result(%{result: result, next_state: nil}), do: result
  def result(%{result: {:ok, armed}, next_state: next}), do: {:ok, armed, next_state: next}
  def result(%{result: result}), do: result
end
