# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Message.EnvironmentState do
  @moduledoc """
  The air around the robot.

  This is ambient temperature from a sensor sitting on the board, not the
  temperature of the SoC — the T113 has no thermal zone, so its own temperature
  can't be read at all.

  ## Fields

  - `temperature` - degrees celsius
  - `humidity` - relative humidity as a percentage
  """

  defstruct [:temperature, :humidity]

  use BB.Message,
    schema: [
      temperature: [
        type: :float,
        required: true,
        doc: "Ambient temperature in degrees celsius"
      ],
      humidity: [
        type: :float,
        required: true,
        doc: "Relative humidity as a percentage"
      ]
    ]

  @type t :: %__MODULE__{temperature: float, humidity: float}
end
