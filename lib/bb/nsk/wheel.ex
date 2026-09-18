# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Wheel do
  @moduledoc """
  Drives one wheel through a DRV8837 H-bridge.

  The bridge takes two inputs. Holding one low and pulsing the other turns the
  motor in the corresponding direction, so direction is which of the two
  channels carries the duty cycle, and speed is how much. Both low is coast.

  There is no encoder, so this is open loop: a velocity is turned into a duty
  cycle in proportion to `max_velocity`, and a commanded velocity is a request
  rather than a promise — nothing here knows how fast the wheel is actually
  going.

  `max_velocity` defaults to the 300 rpm N20's rating at the 6.18 V the boost
  converter measures under load: 31.4 rad/s, or 0.67 m/s at a 21.5 mm wheel.
  That is a no-load figure, and the real one under the robot's weight is lower.

  It is deliberately **not** a tunable parameter, because it is a fact about the
  motor rather than a knob: changing it silently rescales every gain in the
  balance controller, so anyone reaching for it to change the robot's behaviour
  wants a gain instead. Fitting a different motor is a rebuild.

  The gains survive a motor swap, which is the point of the control law speaking
  rad/s rather than duty: a command of 7 rad/s is 13% duty on a 500 rpm motor and
  22% on a 300, and both turn the wheel at 7 rad/s.

  ## Why a 300 rpm motor

  Chosen over the 500 it replaced, and over the 200, for the deadband rather than
  for speed or torque. Catching a thirty degree lean wants about 16 rad/s, so the
  300 has twice what it needs and the 200 would saturate during exactly the
  recoveries that matter. What the 500 cost was the width of the deadband, which
  near balance the controller spends its time crossing in both directions: 5% of
  duty on a 500, which is 2.6 rad/s of wheel speed, against 1% on a 300, which is
  0.3. Nine times narrower, where the argument for swapping had only predicted a
  third — more gearing multiplies motor torque against roughly the same output
  friction, so a slower motor breaks away at a lower duty rather than the higher
  one stiction would suggest.

  Torque never came into it: recovering from thirty degrees needs about 10 mN·m
  a wheel and every variant in the drawer has several times that.

  `Command.Position` and `Command.Effort` are deliberately not accepted. Without
  an encoder this driver could only pretend to honour them, and BB refuses a
  payload the driver doesn't declare before it ever arrives.

  ## Stop coasts, hold brakes

  Driving both of the bridge's inputs high is its brake mode: both outputs go
  low, shorting the motor through the two low side FETs so its own back-EMF
  opposes rotation. `Stop` coasts and `Hold` brakes, which is BB's distinction
  between becoming passive and resisting an external force.

  **The brake is not a position hold, and this driver's `Hold` is weaker than
  the one BB describes.** Braking torque comes from back-EMF, so it falls away
  with speed and is zero at a standstill: it resists *motion*, not
  *displacement*. Push a braked wheel and it yields, it just fights being turned
  quickly. Holding an actual position needs an encoder to know the position has
  been lost, which is the same reason `Command.Position` is refused. Brake is
  the closest the hardware gets, and on a robot on wheels the difference between
  rolling away and not is worth having.

  The bridge's sleep pin is held low until something asks the wheel to move, and
  `disarm/1` drives it low again. That is the state with the motor outputs in
  high impedance, so a disarmed robot cannot drive the motor no matter what the
  PWM channels are left doing.

  ## The watchdog

  **A duty cycle written to the kernel stays written.** Nothing about a PWM
  channel expires, so a wheel told to run at full speed runs at full speed until
  something tells it otherwise — and the thing doing the telling is a controller
  that can crash, block, or decide it has fallen over and stop talking. That is
  how a robot on its side ends up with its wheels at full speed.

  So a wheel that hears nothing for `command_timeout` coasts. It is not a
  substitute for a controller that stops properly, and it is deliberately not a
  brake: the case it exists for is the one where nobody knows what is going on,
  and going passive is the honest response to that.
  """

  use BB.Actuator,
    options_schema: [
      forward_pwm: [
        type: :non_neg_integer,
        required: true,
        doc: "PWM channel that turns the wheel forwards"
      ],
      reverse_pwm: [
        type: :non_neg_integer,
        required: true,
        doc: "PWM channel that turns the wheel backwards"
      ],
      enable_pin: [
        type: :string,
        required: true,
        doc: "GPIO line wired to the bridge's sleep pin"
      ],
      frequency: [
        type: :pos_integer,
        default: 20_000,
        doc: "PWM frequency in hertz. Above hearing, so the motors don't whine"
      ],
      max_velocity: [
        type: :float,
        default: 31.4,
        doc: "Wheel speed in rad/s at full duty, from the motor's rating"
      ],
      decay: [
        type: {:in, [:slow, :fast]},
        default: :slow,
        doc: "What the bridge does between pulses. `:slow` recirculates, `:fast` coasts"
      ],
      deadband: [
        type: :float,
        default: 0.01,
        doc: "Duty below which the motor doesn't turn, skipped over so no command is wasted"
      ],
      command_timeout: [
        type: :non_neg_integer,
        default: 250,
        doc: "Milliseconds of silence after which the wheel coasts. Zero to never give up"
      ]
    ]

  alias BB.Message
  alias BB.Message.Actuator.Command
  alias BB.NSK.PWM
  alias Circuits.GPIO

  require Logger

  # `BB.NSK.PWM` skips a write when the value hasn't changed, but it compares
  # nanoseconds, and at 20 kHz the period is 50,000 of them — so the comparison
  # never matches a control loop's output and never saves anything. Rounding to
  # 500 steps makes it match.
  #
  # It costs nothing physical. A step is 0.06 rad/s of wheel speed at the default
  # `max_velocity`, 1.4 mm/s at the rim, well under the duty the motors need
  # before they turn at all. What it buys is the quiet case: balancing steadily,
  # the command moves by about 0.01% of full scale between samples — gyro noise
  # through the derivative gain — so nearly every write becomes a no-op.
  #
  # Coarser than the hardware, which at 20 kHz resolves the period more finely
  # than this. That is the point: the skipping is worth more than the resolution.
  @duty_steps 500

  @doc """
  The duty cycle a velocity asks for, as a fraction of full scale.

  Signed: negative turns the wheel backwards. Anything beyond what the wheel can
  do is clamped rather than wrapped, so asking for twice the top speed gives
  full duty rather than something surprising.

  Rounded to #{@duty_steps} steps, so that a command which has barely moved
  doesn't cost a syscall to tell the kernel so.
  """
  @spec drive_ratio(float, float) :: float
  def drive_ratio(_velocity, max_velocity) when max_velocity <= 0.0, do: 0.0

  def drive_ratio(velocity, max_velocity) do
    velocity
    |> Kernel./(max_velocity)
    |> max(-1.0)
    |> min(1.0)
    |> Kernel.*(@duty_steps)
    |> round()
    |> Kernel./(@duty_steps)
  end

  @doc """
  Move a duty ratio above the duty the motor ignores.

  Measured on the bench, unloaded: in fast decay the 500 rpm motors needed 40%
  duty to keep turning and 60% to start from rest; slow decay took that to 5%,
  and fitting 300 rpm motors took it to 1%. A balance controller lives near zero
  output, so whatever is left of the deadband sits squarely across the part of
  the range it actually uses, and without this the loop is dead until the robot
  is already falling.

  Squashing the range instead of shifting it keeps full duty meaning full duty.
  The response is discontinuous at zero — the smallest non-zero command jumps
  straight to the deadband — which is the honest trade: a step you can see beats
  a dead zone you can't.
  """
  @spec compensate(float, float) :: float
  def compensate(ratio, _deadband) when ratio == 0.0, do: 0.0
  def compensate(ratio, deadband) when ratio > 0.0, do: deadband + (1.0 - deadband) * ratio
  def compensate(ratio, deadband), do: -deadband + (1.0 - deadband) * ratio

  @impl BB.Actuator
  def command_payloads(_opts), do: [Command.Hold, Command.Stop, Command.Velocity]

  @impl BB.Actuator
  def init(opts) do
    frequency = Keyword.fetch!(opts, :frequency)
    timeout = Keyword.fetch!(opts, :command_timeout)

    if timeout > 0, do: :timer.send_interval(max(div(timeout, 4), 10), :watchdog)

    # The sleep pin goes low before anything touches the PWM channels. Claiming
    # a channel means enabling it, and the bridge will drive whatever its inputs
    # are doing if it is awake — so put it to sleep first and the inputs stop
    # mattering.
    with {:ok, enable} <- GPIO.open(Keyword.fetch!(opts, :enable_pin), :output, initial_value: 0),
         :ok <- GPIO.write(enable, 0),
         {:ok, forward} <- PWM.open(Keyword.fetch!(opts, :forward_pwm), frequency),
         {:ok, reverse} <- PWM.open(Keyword.fetch!(opts, :reverse_pwm), frequency) do
      {:ok,
       %{
         forward: forward,
         reverse: reverse,
         enable: enable,
         mode: :coast,
         decay: Keyword.fetch!(opts, :decay),
         deadband: Keyword.fetch!(opts, :deadband),
         max_velocity: Keyword.fetch!(opts, :max_velocity),
         command_timeout: timeout,
         commanded_at: nil
       }}
    else
      {:error, reason} ->
        Logger.info(
          "Could not claim the hardware for #{inspect(__MODULE__)} " <>
            "(#{inspect(reason)}), so it is not starting."
        )

        :ignore
    end
  end

  @impl BB.Actuator
  def handle_command(%Message{payload: %Command.Hold{}}, state) do
    {:noreply, brake(commanded(state))}
  end

  def handle_command(%Message{payload: %Command.Stop{}}, state) do
    {:noreply, coast(commanded(state))}
  end

  def handle_command(%Message{payload: %Command.Velocity{velocity: velocity}}, state) do
    ratio =
      velocity
      |> drive_ratio(state.max_velocity)
      |> compensate(state.deadband)

    {:noreply, drive(commanded(state), ratio)}
  end

  @impl BB.Actuator
  def handle_info(:watchdog, state) do
    {:noreply, watchdog(state, System.monotonic_time(:millisecond))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl BB.Actuator
  def handle_options(opts, state) do
    # Without this the default implementation drops the new options on the
    # floor, and a parameter that silently does nothing is worse than one that
    # doesn't exist.
    {:ok,
     %{
       state
       | decay: Keyword.fetch!(opts, :decay),
         deadband: Keyword.fetch!(opts, :deadband),
         max_velocity: Keyword.fetch!(opts, :max_velocity)
     }}
  end

  @impl BB.Actuator
  def disarm(opts) do
    # This runs when things have already gone wrong, possibly after the process
    # holding the GPIO has died, so it opens its own handle rather than relying
    # on any state having survived.
    with {:ok, enable} <- GPIO.open(Keyword.fetch!(opts, :enable_pin), :output) do
      GPIO.write(enable, 0)
      GPIO.close(enable)
    end
  end

  @doc false
  # Only a driving wheel can time out. A coasting or braking one is already where
  # the watchdog would put it, and a wheel nobody has ever commanded has nothing
  # to give up.
  def watchdog(%{commanded_at: nil} = state, _now), do: state
  def watchdog(%{mode: mode} = state, _now) when mode in [:coast, :brake], do: state

  def watchdog(state, now) do
    if now - state.commanded_at >= state.command_timeout do
      Logger.warning(
        "No command for #{state.command_timeout}ms while driving, so coasting. " <>
          "Something upstream has stopped talking."
      )

      coast(state)
    else
      state
    end
  end

  defp commanded(state), do: %{state | commanded_at: System.monotonic_time(:millisecond)}

  defp drive(state, ratio) when ratio > 0.0 do
    state |> release_brake() |> turn(:forward, :reverse, ratio) |> wake()
  end

  defp drive(state, ratio) when ratio < 0.0 do
    state |> release_brake() |> turn(:reverse, :forward, abs(ratio)) |> wake()
  end

  defp drive(state, _stopped), do: coast(state)

  # `driving` is the input that carries the direction and `idle` the other one.
  #
  # In fast decay the idle input sits low and the driving one is pulsed, so
  # between pulses both are low and the bridge coasts: the winding's current
  # collapses through the body diodes and the torque goes with it. That is where
  # most of the deadband comes from.
  #
  # In slow decay the roles swap. The driving input is held high and the *idle*
  # one is pulsed with the complement, so between pulses both are high — the
  # brake — and the current recirculates through the low side FETs, losing only
  # `r_DS(on)`. Same duty, much more average current, much more torque.
  #
  # The held-high input is written first on purpose. Coming from the other
  # direction that puts both high for the length of one write, which is the
  # brake, whereas the other order would be a full duty pulse the wrong way.
  defp turn(%{decay: :fast} = state, driving, idle, ratio) do
    state
    |> put_channel(idle, PWM.off(Map.fetch!(state, idle)))
    |> put_channel(driving, PWM.set_duty(Map.fetch!(state, driving), ratio))
    |> Map.put(:mode, driving)
  end

  defp turn(state, driving, idle, ratio) do
    state
    |> put_channel(driving, PWM.set_duty(Map.fetch!(state, driving), 1.0))
    |> put_channel(idle, PWM.set_duty(Map.fetch!(state, idle), 1.0 - ratio))
    |> Map.put(:mode, driving)
  end

  defp put_channel(state, channel, pwm), do: Map.put(state, channel, pwm)

  defp brake(state) do
    # The sleep pin goes down while the inputs are rearranged. Raising one of
    # them before the other would be a full duty drive in that direction for as
    # long as the second write takes, and the outputs are high impedance while
    # the bridge sleeps, so the motor coasts through the change instead. Waking
    # costs 30 us.
    state = sleep(state)

    %{
      state
      | forward: PWM.set_duty(state.forward, 1.0),
        reverse: PWM.set_duty(state.reverse, 1.0),
        mode: :brake
    }
    |> wake()
  end

  defp coast(state) do
    state = release_brake(state)

    %{
      state
      | forward: PWM.off(state.forward),
        reverse: PWM.off(state.reverse),
        mode: :coast
    }
  end

  # Leaving a brake has the same hazard as entering one, in reverse: both inputs
  # are high, so lowering either one on its own drives the motor at full duty
  # until the next write lands.
  defp release_brake(%{mode: :brake} = state) do
    state = sleep(state)

    %{state | forward: PWM.off(state.forward), reverse: PWM.off(state.reverse), mode: :coast}
  end

  defp release_brake(state), do: state

  # Written every time rather than tracked. A GPIO write is a NIF at a couple of
  # microseconds against a hundred for a duty cycle, so skipping it saves a fifth
  # of a percent — and `disarm/1` drops this pin from outside the GenServer, so
  # any memory of it here would be wrong after a disarm and the wheel would
  # quietly refuse to turn once re-armed.
  defp wake(state) do
    GPIO.write(state.enable, 1)

    state
  end

  defp sleep(state) do
    GPIO.write(state.enable, 0)

    state
  end
end
