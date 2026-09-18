# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.PWM do
  @moduledoc """
  The kernel's PWM channels, through sysfs.

  A channel has to be exported before its directory exists, after which it wants
  a period, a duty cycle — both in nanoseconds — and enabling. Duty is an
  absolute time rather than a fraction, so it is computed against the period.

  The T113's controller offers eight channels on `pwmchip0`. The Beam Bots
  add-on board uses four of them: 2 and 3 for one motor, 4 and 5 for the other.
  None of them exist unless the board booted the `nsk-balance-bot` device tree.

  ## Everything possible happens at open time

  Setting a duty cycle is on the balance controller's hot path. A descriptor
  opened once in `:raw` mode and rewritten with `:file.pwrite/3` is far cheaper
  than `File.write/2`, which goes through the file server — a port round trip per
  call — and opens and closes the file every time.

  So `open/3` returns a struct holding the descriptor and the period, and
  `set_duty/2` does arithmetic and one `pwrite`. The struct also remembers what
  it last wrote and skips the call when nothing changed, which matters more than
  it sounds: driving steadily forwards leaves the reverse channel at zero, and
  rewriting that zero two hundred times a second was half the cost of running.

  ## What a write actually costs

  Measured on the board, 2000 iterations, robot disarmed and otherwise idle:

  | | median | p95 | p99 | max |
  |---|---|---|---|---|
  | `pwrite` to `duty_cycle` | **0.108 ms** | 0.265 | 1.278 | 2.415 |
  | `pwrite` to tmpfs, no driver | 0.066 ms | 0.179 | 1.139 | 18.567 |

  **The kernel is nearly free.** Forty-two microseconds separate a write that
  reaches a hardware register from one that lands on tmpfs, and the cost does not
  move with the PWM period — measured at 20 kHz, 1 kHz and 100 Hz, a 200x range,
  the median varied by 41 us. The driver is not waiting for a period boundary to
  latch, so there is no point looking for savings there.

  The sustained ceiling is about **8,600 writes a second**. Both wheels at 200 Hz
  come to about 5% of a core.

  **The tail is the BEAM's, not sysfs's.** Roughly 1% of writes take over a
  millisecond, and the worst outlier of the whole run — 18.6 ms — was on *tmpfs*,
  where no driver is involved at all. That is the async IO path: the dirty
  scheduler handoff, garbage collection, or preemption. It is the most likely
  explanation for the 1% of loop ticks that arrive late while the wheels are
  driving, and it is not addressable without leaving `:file` for a NIF.

  When re-measuring any of this, quote the median and the distribution. A
  hundred-sample mean of this operation is contaminated by that tail badly enough
  to come out ten times too high, which has happened.
  """

  @chip "pwmchip0"
  @path "/sys/class/pwm"

  defstruct [:path, :file, :period, duty: 0]

  @type t :: %__MODULE__{
          path: Path.t(),
          file: File.io_device(),
          period: pos_integer,
          duty: non_neg_integer
        }

  @typedoc "A duty cycle from 0.0 to 1.0."
  @type duty :: float

  @doc """
  Whether the kernel is offering PWM at all.

  False on the host, and false on a board that booted the stock
  `nerves-starter-kit` device tree.
  """
  @spec available?(String.t()) :: boolean
  def available?(chip \\ @chip), do: File.dir?(Path.join(@path, chip))

  @doc """
  Claim a channel, set it running at `frequency` hertz with zero duty, and hold
  a descriptor open on its duty cycle.

  Polarity is set explicitly rather than taken on trust: inverted, a duty of
  zero is a constant high rather than a constant low, which at a motor bridge is
  the difference between resting and driving. It can only be set while the
  channel is disabled, which is why the channel is disabled first.

  Exporting a channel that is already exported is not an error — it survives a
  restart of the process that claimed it — so that case is expected rather than
  exceptional.
  """
  @spec open(non_neg_integer, pos_integer, String.t()) :: {:ok, t} | {:error, term}
  def open(channel, frequency, chip \\ @chip) do
    chip_path = Path.join(@path, chip)
    channel_path = Path.join(chip_path, "pwm#{channel}")
    period = period(frequency)

    with :ok <- export(chip_path, channel_path, channel),
         :ok <- write(channel_path, "enable", "0"),
         :ok <- set_polarity(channel_path),
         :ok <- write(channel_path, "duty_cycle", "0"),
         :ok <- write(channel_path, "period", Integer.to_string(period)),
         :ok <- write(channel_path, "duty_cycle", "0"),
         :ok <- write(channel_path, "enable", "1"),
         {:ok, file} <- File.open(Path.join(channel_path, "duty_cycle"), [:write, :raw]) do
      {:ok, %__MODULE__{path: channel_path, file: file, period: period, duty: 0}}
    end
  end

  @doc """
  Set a channel's duty cycle, as a fraction of its period.

  Returns the channel, which remembers what it wrote.
  """
  @spec set_duty(t, duty) :: t
  def set_duty(%__MODULE__{period: period} = pwm, duty) when duty >= 0.0 and duty <= 1.0 do
    write_duty(pwm, round(period * duty))
  end

  @doc """
  Stop a channel driving, without giving up the claim on it.
  """
  @spec off(t) :: t
  def off(%__MODULE__{} = pwm), do: write_duty(pwm, 0)

  @doc """
  The period in nanoseconds for a frequency in hertz.
  """
  @spec period(pos_integer) :: pos_integer
  def period(frequency) when frequency > 0, do: div(1_000_000_000, frequency)

  # A syscall to tell the kernel what it already knows.
  defp write_duty(%__MODULE__{duty: duty} = pwm, duty), do: pwm

  defp write_duty(pwm, duty) do
    :file.pwrite(pwm.file, 0, Integer.to_string(duty))

    %{pwm | duty: duty}
  end

  # Not every controller offers polarity, so failing to set it is not fatal —
  # the sunxi driver defaults to normal, which is what we want anyway.
  defp set_polarity(channel_path) do
    case write(channel_path, "polarity", "normal") do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp export(chip_path, channel_path, channel) do
    case File.dir?(channel_path) do
      true ->
        :ok

      false ->
        with :ok <- File.write(Path.join(chip_path, "export"), Integer.to_string(channel)) do
          # The kernel creates the directory asynchronously, and udev may still
          # be adjusting its permissions when it appears.
          await_channel(channel_path, 50)
        end
    end
  end

  defp await_channel(channel_path, 0), do: {:error, {:export_timeout, channel_path}}

  defp await_channel(channel_path, attempts) do
    case File.dir?(channel_path) do
      true ->
        :ok

      false ->
        Process.sleep(10)
        await_channel(channel_path, attempts - 1)
    end
  end

  defp write(channel_path, attribute, value) do
    File.write(Path.join(channel_path, attribute), value)
  end
end
