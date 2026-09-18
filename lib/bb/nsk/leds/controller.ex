# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Leds.Controller do
  @moduledoc """
  Shows the robot's safety state on the NeoPixels.

  The panel says the same thing, but takes the better part of three seconds to
  say it. These are immediate, which is what you want from something telling you
  whether the robot is about to move.

  All four show the same colour rather than being used as a bar: the point is to
  be readable from wherever you happen to be standing.

  They breathe rather than sitting still, which reads as a robot that is running
  rather than one that has locked up.

  One timer here drives all four, rather than each pixel running the kernel's
  pattern trigger. Four independent timers each reschedule against themselves,
  so their errors accumulate separately and the pixels visibly drift apart over
  minutes. Brightness is worked out from the monotonic clock rather than
  accumulated tick by tick, so a late or dropped tick costs a frame instead of
  shifting the phase permanently.

  They are turned off when the robot shuts down, since the board stays powered
  and would otherwise leave them lit with nothing behind them.
  """

  use BB.Controller,
    options_schema: [
      brightness: [
        type: :non_neg_integer,
        default: 40,
        doc:
          "Brightness at the top of the pulse, 0 to the device's maximum. These " <>
            "are bright enough to be uncomfortable at full scale, and draw " <>
            "current to match"
      ],
      pulse: [
        type: :boolean,
        default: true,
        doc: "Whether to breathe. Held steady at `brightness` when false"
      ],
      pulse_period: [
        type: :pos_integer,
        default: 2_000,
        doc: "Milliseconds for a full breath, in and out"
      ],
      flash_period: [
        type: :pos_integer,
        default: 250,
        doc: "Milliseconds for a full flash while fallen. Fast, because it wants attention"
      ],
      pulse_interval: [
        type: :pos_integer,
        default: 50,
        doc: "Milliseconds between brightness updates while breathing"
      ],
      clear_on_shutdown: [
        type: :boolean,
        default: true,
        doc: "Whether to turn the pixels off when the robot shuts down"
      ]
    ]

  alias BB.{Message, PubSub}
  alias BB.NSK.Leds
  alias BB.Robot.Runtime
  alias BB.StateMachine.Transition

  require Logger

  # Keyed on the operational state, which subsumes the safety one: a disarmed
  # robot reports `:disarmed` here too. `:fallen` flashes rather than breathes,
  # because it is the one state that is asking the operator for something, and
  # a breath reads as "working" no matter what colour it is.
  @patterns %{
    disarmed: {{0, 0, 255}, :breathe},
    idle: {{0, 255, 0}, :breathe},
    executing: {{0, 255, 0}, :breathe},
    balancing: {{0, 255, 0}, :breathe},
    fallen: {{255, 0, 180}, :flash},
    disarming: {{255, 120, 0}, :breathe},
    error: {{255, 0, 0}, :breathe}
  }

  @unknown {{80, 0, 80}, :breathe}

  @doc """
  The brightness of a breath `elapsed` milliseconds in.

  A raised cosine, so it eases at both ends rather than turning corners the way
  a triangle would. Phase comes from elapsed time rather than a counter, which
  is what keeps every pixel together no matter how the timer behaves.
  """
  @spec breath(non_neg_integer, non_neg_integer, non_neg_integer, pos_integer) ::
          non_neg_integer
  def breath(elapsed, peak, floor, period) do
    phase = rem(elapsed, period) / period

    floor + round((peak - floor) * (1 - :math.cos(2 * :math.pi() * phase)) / 2)
  end

  @doc """
  The brightness of a flash `elapsed` milliseconds in.

  Square rather than eased: on for the first half of the period, off for the
  second. A breath says the robot is busy; a flash says it wants something.
  """
  @spec flash(non_neg_integer, non_neg_integer, non_neg_integer, pos_integer) ::
          non_neg_integer
  def flash(elapsed, peak, floor, period) do
    if rem(elapsed, period) / period < 0.5, do: peak, else: floor
  end

  @doc """
  The colour a state is shown in, and whether it breathes or flashes.
  """
  @spec pattern(atom) :: {Leds.colour(), :breathe | :flash}
  def pattern(state), do: Map.get(@patterns, state, @unknown)

  @doc """
  The colour a state is shown in.
  """
  @spec colour(atom) :: Leds.colour()
  def colour(state), do: state |> pattern() |> elem(0)

  @impl BB.Controller
  def init(opts) do
    %{robot: robot} = Keyword.fetch!(opts, :bb)

    start(robot, opts, Leds.open_all())
  end

  @impl BB.Controller
  def handle_continue(:show_state, state), do: {:noreply, show(state)}

  @impl BB.Controller
  def handle_info({:bb, _path, %Message{payload: %Transition{to: to}}}, state) do
    {:noreply, show(%{state | operational: to})}
  end

  def handle_info(:breathe, state) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at
    {_colour, profile} = pattern(state.operational)

    pixels =
      state
      |> pulse(profile, elapsed)
      |> then(&Leds.set_brightness_all(state.pixels, &1))

    {:noreply, %{state | pixels: pixels}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl BB.Controller
  def handle_options(opts, state) do
    state = %{
      state
      | brightness: brightness(opts, state.max_brightness),
        pulse_period: Keyword.fetch!(opts, :pulse_period),
        flash_period: Keyword.fetch!(opts, :flash_period)
    }

    state =
      if state.pulse do
        state
      else
        %{state | pixels: Leds.set_brightness_all(state.pixels, state.brightness)}
      end

    {:ok, show(state)}
  end

  @impl BB.Controller
  def terminate(_reason, %{clear_on_shutdown: true}) do
    Leds.off()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start(_robot, _opts, []) do
    Logger.info("No NeoPixels found, so #{inspect(__MODULE__)} is not starting.")

    :ignore
  end

  defp start(robot, opts, [pixel | _rest] = pixels) do
    Process.flag(:trap_exit, true)
    {:ok, _subscription} = PubSub.subscribe(robot, [:state_machine])

    max = Leds.max_brightness(pixel.path) || 255

    # Brightness is ours to drive, so make sure nothing in the kernel is also
    # driving it.
    Enum.each(pixels, &Leds.release(&1.path))

    state = %{
      robot: robot,
      pixels: pixels,
      operational: Runtime.state(robot),
      max_brightness: max,
      brightness: brightness(opts, max),
      pulse: Keyword.fetch!(opts, :pulse),
      pulse_period: Keyword.fetch!(opts, :pulse_period),
      flash_period: Keyword.fetch!(opts, :flash_period),
      started_at: System.monotonic_time(:millisecond),
      clear_on_shutdown: Keyword.fetch!(opts, :clear_on_shutdown)
    }

    state =
      if state.pulse do
        :timer.send_interval(Keyword.fetch!(opts, :pulse_interval), :breathe)
        state
      else
        %{state | pixels: Leds.set_brightness_all(state.pixels, state.brightness)}
      end

    {:ok, state, {:continue, :show_state}}
  end

  defp brightness(opts, max), do: opts |> Keyword.fetch!(:brightness) |> min(max) |> max(0)

  # Dimming to nothing would read as an LED that has gone out, so a breath
  # bottoms out at a glow.
  defp dimmest(state), do: div(state.brightness, 8)

  defp pulse(state, :flash, elapsed) do
    flash(elapsed, state.brightness, dimmest(state), state.flash_period)
  end

  defp pulse(state, :breathe, elapsed) do
    breath(elapsed, state.brightness, dimmest(state), state.pulse_period)
  end

  defp show(state) do
    {colour, _profile} = pattern(state.operational)
    Leds.set_all(state.pixels, colour)

    state
  end
end
