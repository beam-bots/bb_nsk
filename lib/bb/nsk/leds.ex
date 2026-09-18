# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Leds do
  @moduledoc """
  The four NeoPixels on the add-on board.

  The kernel drives them, so they are files rather than a protocol: each pixel is
  a multicolour LED class device with `multi_intensity` for the three channels
  and `brightness` as a master scale over them. Brightness has to be non-zero for
  anything to light, whatever the intensities say.

  Because colour and brightness are separate, a pulse can be driven by writing
  brightness alone and leaving the colour where it is.

  `indicator-0` is the rightmost pixel as the robot is mounted, so they run right
  to left. That only matters if they are ever used as a bar rather than all
  showing the same thing, but it is the sort of thing nobody wants to work out
  twice.

  ## Brightness is on a hot path and colour isn't

  A breath rewrites brightness on every pixel twenty times a second, and on this
  board a `File.write/2` to sysfs costs 5.86 ms — so doing that the obvious way
  spent about half a core on making some LEDs fade, permanently, whether or not
  the robot was doing anything. It was worse than it looks: the write happened
  through a helper that globbed the LED directory each time to find the pixels.

  So `open/1` resolves a pixel once — its path, its channel order, and a
  descriptor held open on `brightness` — and `set_brightness/2` is one
  `:file.pwrite/3` against that descriptor, skipped entirely when the value
  hasn't changed. Colour goes through `File.write/2` still, because it changes
  only when the safety state does.

  `off/0` deliberately stays path-based and stateless. It runs from `terminate`,
  when whatever held those descriptors may already be gone.
  """

  require Logger

  @path "/sys/class/leds"
  @pattern "rgb:indicator-*"

  defstruct [:path, :file, :order, brightness: nil]

  @type t :: %__MODULE__{
          path: Path.t(),
          file: File.io_device(),
          order: [:red | :green | :blue],
          brightness: non_neg_integer | nil
        }

  @typedoc "Red, green and blue, each 0..255."
  @type colour :: {0..255, 0..255, 0..255}

  @doc """
  Resolve a pixel and hold its `brightness` open, ready to be written to often.
  """
  @spec open(Path.t()) :: {:ok, t} | {:error, term}
  def open(device) do
    with {:ok, file} <- File.open(Path.join(device, "brightness"), [:write, :raw]) do
      {:ok, %__MODULE__{path: device, file: file, order: channel_order(device)}}
    end
  end

  @doc """
  Every pixel, opened and ready. Empty when the hardware isn't there.
  """
  @spec open_all() :: [t]
  def open_all do
    devices()
    |> Enum.map(&open/1)
    |> Enum.flat_map(fn
      {:ok, pixel} ->
        [pixel]

      {:error, reason} ->
        Logger.warning("Could not open a NeoPixel: #{inspect(reason)}")
        []
    end)
  end

  @doc """
  Every pixel, in the order the kernel names them.
  """
  @spec devices() :: [Path.t()]
  def devices do
    @path
    |> Path.join(@pattern)
    |> Path.wildcard()
    |> Enum.sort_by(&index/1)
  end

  @doc """
  The largest value `brightness` accepts, or `nil` if the device isn't there.
  """
  @spec max_brightness(Path.t()) :: pos_integer | nil
  def max_brightness(device) do
    with {:ok, contents} <- File.read(Path.join(device, "max_brightness")),
         {value, _rest} <- Integer.parse(String.trim(contents)) do
      value
    else
      _unavailable -> nil
    end
  end

  @doc """
  The order this device wants its channels in, as read from `multi_index`.

  Almost always `[:red, :green, :blue]` — the driver deals with the wire order
  these things actually use — but it is written down, so read it rather than
  assume it.
  """
  @spec channel_order(Path.t()) :: [:red | :green | :blue]
  def channel_order(device) do
    case File.read(Path.join(device, "multi_index")) do
      {:ok, contents} -> contents |> String.split() |> Enum.map(&channel/1)
      _unavailable -> [:red, :green, :blue]
    end
  end

  @doc """
  Set one pixel's colour, leaving its brightness alone.

  Separate from brightness so that a colour can change without interrupting a
  pulse, which drives brightness underneath it.
  """
  @spec set_colour(t | Path.t(), colour) :: :ok | {:error, term}
  def set_colour(%__MODULE__{} = pixel, colour) do
    write_colour(pixel.path, pixel.order, colour)
  end

  def set_colour(device, colour) when is_binary(device) do
    write_colour(device, channel_order(device), colour)
  end

  defp write_colour(device, order, colour) do
    intensity = Enum.map_join(order, " ", &Integer.to_string(channel_value(colour, &1)))

    File.write(Path.join(device, "multi_intensity"), intensity)
  end

  @doc """
  Take a pixel off whatever kernel trigger it was on, so that brightness is ours
  to set.
  """
  @spec release(Path.t()) :: :ok | {:error, term}
  def release(device), do: File.write(Path.join(device, "trigger"), "none")

  @doc """
  Set a pixel's brightness, leaving its colour alone.

  Returns the pixel, which remembers what it wrote so that an unchanged value
  costs nothing.
  """
  @spec set_brightness(t, non_neg_integer) :: t
  def set_brightness(%__MODULE__{brightness: brightness} = pixel, brightness), do: pixel

  def set_brightness(%__MODULE__{} = pixel, brightness) do
    :file.pwrite(pixel.file, 0, Integer.to_string(brightness))

    %{pixel | brightness: brightness}
  end

  @doc """
  Set every pixel's brightness.
  """
  @spec set_brightness_all([t], non_neg_integer) :: [t]
  def set_brightness_all(pixels, brightness) do
    Enum.map(pixels, &set_brightness(&1, brightness))
  end

  @doc """
  Set every pixel to the same colour.
  """
  @spec set_all([t], colour) :: :ok
  def set_all(pixels, colour) do
    Enum.each(pixels, fn pixel ->
      with {:error, reason} <- set_colour(pixel, colour) do
        Logger.warning("Could not set #{Path.basename(pixel.path)}: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Turn every pixel off, and stop any pulse.
  """
  @spec off() :: :ok
  def off do
    Enum.each(devices(), fn device ->
      with :ok <- release(device),
           :ok <- set_colour(device, {0, 0, 0}),
           :ok <- File.write(Path.join(device, "brightness"), "0") do
        :ok
      else
        {:error, reason} ->
          Logger.warning("Could not turn off #{Path.basename(device)}: #{inspect(reason)}")
      end
    end)
  end

  defp channel_value({red, _green, _blue}, :red), do: red
  defp channel_value({_red, green, _blue}, :green), do: green
  defp channel_value({_red, _green, blue}, :blue), do: blue

  defp channel("red"), do: :red
  defp channel("green"), do: :green
  defp channel("blue"), do: :blue

  # The pixels are named `indicator-0` through `indicator-3`, and sorting those
  # as strings would fall apart the moment there were ten of them.
  defp index(device) do
    device
    |> Path.basename()
    |> String.split("-")
    |> List.last()
    |> Integer.parse()
    |> case do
      {index, _rest} -> index
      :error -> 0
    end
  end
end
