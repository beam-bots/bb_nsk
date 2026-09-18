# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Message.Drive do
  @moduledoc """
  What a pilot is asking the robot to do.

  ## Why this is a throttle and not a velocity

  A `BB.Message.Geometry.Twist2D` would be the conventional thing to send, and it
  would be a lie. Its `vx` is a linear velocity, and **this robot cannot be asked
  to travel at a speed**: with no encoders it has no idea how fast it is going, so
  there is nothing to close a velocity loop with.

  Trying anyway is how this message came to exist. The balance controller's trim
  regulates the *commanded* wheel velocity, which looked like a velocity loop with
  the target hardcoded to zero — so pointing it at a non-zero target seemed free.
  It isn't: the commanded wheel velocity is `kp` times the lean error, so holding
  it at a value means holding a lean error, and a constant lean error is a
  constant *acceleration*. Asked for 4 rad/s the robot obediently accelerated
  through 6, 9, 13, 18 and fell over.

  The trim works at zero because zero sustained command genuinely does mean not
  accelerating. That is a regulator. Any other target is an instruction to
  accelerate until something stops it.

  So `throttle` is what it says: a fraction of the lean the controller is willing
  to spend on going somewhere. Push it and the robot accelerates; let go and it
  leans back and stops. The pilot regulates speed by watching, which is the same
  loop a Segway rider closes and is the whole of what this sensor set supports.

  `turn` is a genuine rate, because yaw *is* measured — the gyroscope reports it
  directly and the heading loop tracks it properly. The asymmetry between the two
  fields is the asymmetry in what the robot can sense.

  ## Fields

  - `throttle` - lean to spend on driving, as a fraction of the controller's
    `drive_limit`. Positive is forwards.
  - `turn` - yaw rate to hold, in radians per second. Positive is to the robot's
    left.
  """

  defstruct [:throttle, :turn]

  use BB.Message,
    schema: [
      throttle: [
        type: :float,
        required: true,
        doc: "Lean to spend on driving, -1 to 1, positive forwards"
      ],
      turn: [
        type: :float,
        required: true,
        doc: "Yaw rate in radians per second, positive to the robot's left"
      ]
    ]

  @type t :: %__MODULE__{throttle: float, turn: float}
end
