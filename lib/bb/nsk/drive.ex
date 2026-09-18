# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Drive do
  @moduledoc """
  Where a pilot's intentions reach the balance controller.

  A `BB.NSK.Message.Drive` on `[:drive]` — a throttle and a turn rate. That
  message's moduledoc explains why the throttle is not a velocity, which is the
  thing most worth knowing before using this.

  Pubsub rather than `BB.Command`, because a command is a spawned process with a
  goal and a result, meant for things like arming. This is a stream at twenty
  hertz that is stale the moment the next one arrives.

  ## Letting go stops it

  Both axes settle rather than latch. The throttle returns to zero, the robot
  leans back to its balance point and rolls to a stop; the turn rate returns to
  zero and the heading loop holds wherever it got to.

  And a command is only good for `drive_timeout` — see the balance controller —
  so a phone that walks out of wifi range stops the robot rather than leaving it
  driving on its last instruction.
  """

  alias BB.NSK.Message.Drive

  @path [:drive]

  @doc "The topic drive commands are published on."
  @spec path() :: [atom]
  def path, do: @path

  @doc """
  Ask the robot to lean `throttle` and turn at `turn` radians a second.

  `throttle` runs -1 to 1 and is a fraction of the lean the controller will spend
  on driving, not a speed. Positive is forwards and to the robot's left.
  """
  @spec command(module, number, number) :: :ok
  def command(robot, throttle, turn) do
    {:ok, message} =
      Drive.new(:base_link,
        throttle: settled(clamp(throttle)),
        turn: settled(turn)
      )

    BB.publish(robot, @path, message)
  end

  @doc """
  Ask for nothing, which is how the robot is stopped.

  Worth calling explicitly on the way out rather than relying on the timeout: the
  timeout is what catches a pilot who has vanished, not a courtesy for one who
  has simply stopped.
  """
  @spec stop(module) :: :ok
  def stop(robot), do: command(robot, 0.0, 0.0)

  # The browser clamps too, but a socket is a public interface and a pad that
  # could be talked into full lean by a crafted message is a poor thing to put on
  # a robot.
  defp clamp(value) when is_number(value), do: value |> max(-1.0) |> min(1.0)
  defp clamp(_value), do: 0.0

  # Negating a zero deflection produces `-0.0`, which is `==` to zero but does not
  # *match* it — so a consumer written to recognise a stopped robot with
  # `%Drive{throttle: 0.0}` would silently fail to. Adding zero settles it.
  defp settled(value), do: value + 0.0
end
