# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Sensor.Environment do
  @moduledoc """
  Reads ambient temperature and humidity from the board's HTS221, and publishes
  them as `BB.NSK.Message.EnvironmentState`.

  The sensor is deliberately placed away from the rest of the board so that it
  reads the air rather than the SoC, so treat it as room temperature and not as
  a measure of how hard the robot is working.

  Nothing changes quickly here, so it is read slowly.
  """

  use BB.Sensor,
    options_schema: [
      bus_name: [
        type: :string,
        default: "i2c-0",
        doc: "The I2C bus the sensor is on"
      ],
      address: [
        type: :pos_integer,
        default: 0x5F,
        doc: "The sensor's I2C address"
      ],
      interval: [
        type: :pos_integer,
        default: :timer.seconds(30),
        doc: "How often to take a reading, in milliseconds"
      ],
      odr: [
        type: {:in, [1, 7, 12.5]},
        default: 1,
        doc: "Output data rate in Hz"
      ]
    ]

  alias BB.NSK.Message.EnvironmentState
  alias Wafer.Driver.Circuits.I2C, as: Backend

  # `hts221` is not on Hex under this API — the package of that name there is a
  # different library — so it cannot be a dependency of this one. `add_environment_sensor`
  # puts the git dep in the consumer's `mix.exs`, and this module is only ever
  # reached by a robot that declared the sensor, which means it is there.
  @compile {:no_warn_undefined, HTS221}

  require Logger

  @impl BB.Sensor
  def init(opts) do
    %{robot: robot, path: path} = Keyword.fetch!(opts, :bb)

    case acquire(opts) do
      {:ok, sensor} ->
        interval = Keyword.fetch!(opts, :interval)
        :timer.send_interval(interval, :read)

        {:ok, %{sensor: sensor, robot: robot, path: path}, {:continue, :read}}

      {:error, reason} ->
        address = Keyword.fetch!(opts, :address) |> Integer.to_string(16)

        Logger.info(
          "No HTS221 at 0x#{address} on #{inspect(Keyword.fetch!(opts, :bus_name))} " <>
            "(#{inspect(reason)}), so #{inspect(__MODULE__)} is not starting."
        )

        :ignore
    end
  end

  @impl BB.Sensor
  def handle_continue(:read, state), do: {:noreply, read(state)}

  @impl BB.Sensor
  def handle_info(:read, state), do: {:noreply, read(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp read(state) do
    with {:ok, %{temperature: temperature, humidity: humidity}} <-
           HTS221.read_sample(state.sensor),
         {:ok, message} <-
           EnvironmentState.new(:base_link, temperature: temperature, humidity: humidity) do
      BB.PubSub.publish(state.robot, [:sensor | state.path], message)
    else
      {:error, reason} ->
        Logger.warning("Could not read the HTS221: #{inspect(reason)}")
    end

    state
  end

  defp acquire(opts) do
    with {:ok, conn} <-
           Backend.acquire(
             bus_name: Keyword.fetch!(opts, :bus_name),
             address: Keyword.fetch!(opts, :address)
           ),
         {:ok, sensor} <- HTS221.acquire(conn: conn) do
      HTS221.configure(sensor, power: :active, odr: Keyword.fetch!(opts, :odr))
    end
  end
end
