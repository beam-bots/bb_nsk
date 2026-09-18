# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Balance.Controller do
  @moduledoc """
  Keeps the robot upright, and knows when it has stopped being able to.

  Runs on every lean sample — the IMU's 100 Hz sets the loop rate — and drives
  both wheels from a PD law on the lean error. Leaning forwards means driving
  forwards to get back underneath, so the sign is straightforward: positive
  error, positive wheel velocity.

  ## Why PD and not something better

  The plant is an inverted pendulum on a cart, which has four states: wheel
  position, wheel velocity, lean and lean rate. There are no encoders, so two of
  those four are unobservable and the cascaded and full-state-feedback designs
  that would use them are not available. PD over the two we measure is not a
  first approximation here, it is the whole of what the hardware supports.

  The consequence is worth stating plainly: **this will not hold station.**
  Nothing in the loop knows where the robot is or how fast it is going, so it
  balances while drifting.

  ## The trim, which is doing more work than it looks

  Holding the wrong lean means accelerating forever, so setpoint error is not a
  cosmetic problem — it is the difference between balancing and running away.
  And the setpoint cannot be measured well enough to avoid it: it comes from the
  centre of mass, whose fore-aft position is a small number on a 20.7 mm body,
  and the angle moves 1.22 degrees for every millimetre of error there.

  So the setpoint is trimmed while running. At the true balance point the robot
  needs no net wheel command to stay there, so a persistent average command
  means the setpoint is wrong, and the trim integrates that average away. It is
  deliberately slow — seconds against the pendulum's 69 ms — because a trim that
  moves at the speed of the balance loop is just a badly tuned integrator, and
  oscillates.

  The accelerometer is the other candidate signal and is a worse one: it cannot
  separate leaning from accelerating, and the AHRS filter absorbs the difference
  into its attitude estimate, so the signal fades at exactly the frequency the
  trim cares about.

  Once it settles on a flat floor the trim is a better measurement of the centre
  of mass than the bench one: `x = z * tan(setpoint + trim)`.

  ## Falling over

  Past `fall_angle` the wheels can't get back underneath, so it brakes them and
  transitions to `:fallen`, where it waits to be picked up. Coming back is
  deliberately harder than leaving: the lean has to be within `catch_angle` of
  the setpoint *and* turning slower than `catch_rate`. Without the rate
  condition it grabs while being carried, because a robot waved about passes
  through upright on the way.
  """

  import BB.Unit
  import BB.Unit.Option

  use BB.Controller,
    options_schema: [
      setpoint: [
        type: unit_type(compatible: :degree),
        default: ~u(0 degree),
        doc: "The lean to hold, before trimming. Negative leans back"
      ],
      proportional_gain: [
        type: :float,
        default: 8.0,
        doc: "Wheel velocity per radian of lean error, in 1/s"
      ],
      derivative_gain: [
        type: :float,
        default: 0.6,
        doc: "Wheel velocity per radian per second of lean rate. Dimensionless"
      ],
      trim_gain: [
        type: :float,
        default: 0.002,
        doc: "How fast the setpoint chases the average wheel command away, in rad/s per unit"
      ],
      trim_limit: [
        type: unit_type(compatible: :degree),
        default: ~u(5 degree),
        doc: "How far the trim may wander. Saturating it means something else is wrong"
      ],
      fall_angle: [
        type: unit_type(compatible: :degree),
        default: ~u(30 degree),
        doc: "Lean error past which it gives up and waits to be stood back up"
      ],
      catch_angle: [
        type: unit_type(compatible: :degree),
        default: ~u(5 degree),
        doc: "Lean error within which it will take over again"
      ],
      catch_rate: [
        type: unit_type(compatible: :degree_per_second),
        default: ~u(20 degree_per_second),
        doc: "How still it must be held before taking over, so it doesn't grab mid-air"
      ],
      # Named rather than a list, because a differential is asymmetric and list
      # position is a poor place to keep a sign. Which way round these go has
      # been got wrong three times on this robot.
      left_wheel: [
        type: :atom,
        default: :left_wheel,
        doc: "The actuator on the robot's left"
      ],
      right_wheel: [
        type: :atom,
        default: :right_wheel,
        doc: "The actuator on the robot's right"
      ],
      yaw_gain: [
        type: :float,
        default: 0.0,
        doc: "Differential wheel velocity per radian of heading error, in 1/s"
      ],
      yaw_damping: [
        type: :float,
        default: 0.0,
        doc: "Differential wheel velocity per radian per second of yaw rate"
      ],
      yaw_limit: [
        type: :float,
        default: 3.0,
        doc: "How much wheel velocity the heading may spend, in rad/s. Balance gets the rest"
      ],
      yaw_tau: [
        type: :float,
        default: 10.0,
        doc: "Seconds for the held heading to follow the measured one, absorbing gyro drift"
      ],
      heading_joint: [
        type: :atom,
        default: :ground,
        doc: "The joint whose rotation is the heading"
      ],
      heading_sensor: [
        type: :atom,
        default: :heading,
        doc: "The sensor on that joint reporting it"
      ],
      # A pilot who walks out of wifi range should stop the robot, not leave it
      # driving on its last instruction. This is also how long a *lost* release
      # takes to stop the robot, so it is the worst case for letting go — the pad
      # sends a stop of its own, and this is what catches the one that didn't
      # arrive. At the pad's twenty hertz it rides out three consecutive losses,
      # which is as much as a stream that stuttering is worth trusting anyway.
      drive_timeout: [
        type: :pos_integer,
        default: 200,
        doc: "Milliseconds a drive command stays good for before it is forgotten"
      ],
      # Bounds the acceleration a pilot can ask for, at roughly `g * tan(this)`.
      # It cannot bound the *speed* — holding a lean accelerates for as long as it
      # is held, and nothing here measures how fast the robot is going — so this
      # is the difference between a robot that runs away gently enough to catch
      # and one that does not.
      drive_limit: [
        type: unit_type(compatible: :degree),
        default: ~u(2 degree),
        doc: "How much lean a full throttle may spend. Bounds acceleration, not speed"
      ],
      # A step in the drive lean is a step in the setpoint, and the loop answers a
      # step with `kp` times it — two degrees at a gain of 180 is a 6.3 rad/s kick
      # on a single sample. Backwards, too, because tipping forwards means driving
      # the wheels back first. This robot is small and light enough that a kick
      # like that is a lurch rather than a nudge, so the lean is walked to where
      # the pilot asked rather than jumped there.
      drive_slew: [
        type: unit_type(compatible: :degree_per_second),
        default: ~u(8 degree_per_second),
        doc: "How fast the drive lean may change. Full throttle takes `limit / this` seconds"
      ],
      # Coming *back* to zero is not the same manoeuvre and does not want the same
      # rate. The kick a step produces drives the wheels forward under a body that
      # is still leaning forward, which is how a balance bot sheds speed — so on
      # the way out that kick is a lurch to be avoided, and on the way back it is
      # the deceleration. Slow out, fast back, because how quickly letting go
      # stops the robot is the thing the pilot judges the pad on.
      drive_release: [
        type: unit_type(compatible: :degree_per_second),
        default: ~u(32 degree_per_second),
        doc: "How fast the drive lean returns towards zero. Letting go takes `limit / this`"
      ],
      lean_joint: [
        type: :atom,
        default: :lean,
        doc: "The joint whose configuration is the lean"
      ],
      lean_sensor: [
        type: :atom,
        default: :lean_angle,
        doc: "The sensor on that joint reporting it"
      ],
      trim_tau: [
        type: :float,
        default: 1.0,
        doc: "Seconds to average the wheel command over before the trim integrates it"
      ],
      # The trim cannot tell "I am driving hard because my setpoint is wrong" from
      # "I am driving hard because somebody shoved me", and integrates both. A
      # shove rails it inside a second, rails it the other way when the recovery
      # overshoots, and leaves the robot balancing against a displaced setpoint for
      # fifteen seconds afterwards — because once calm, the command that would
      # unwind it is nearly zero.
      #
      # So it only learns from a *small persistent* command, which is what a bias
      # looks like. Measured, the two are cleanly separated: calm balancing sits
      # under 0.8 rad/s and a shove produces 4 to 18.
      trim_ceiling: [
        type: :float,
        default: 2.0,
        doc: "Wheel command above which the robot is recovering, not biased, and the trim waits"
      ],
      trace_samples: [
        type: :non_neg_integer,
        default: 400,
        doc: "How many samples of the loop to keep for inspection. Two seconds at 200 Hz"
      ],
      # The loop decides when the robot has fallen and when it can take over
      # again, but it goes through the command system to say so rather than
      # moving the state machine itself — the transition has to be refused if the
      # robot is disarmed, and a command is what knows that. Configurable because
      # a robot gets to name its own commands, and this one has no way to guess.
      stand_command: [
        type: :atom,
        default: :stand,
        doc: "The robot's command for taking over when it is held steady enough"
      ],
      fall_command: [
        type: :atom,
        default: :fall,
        doc: "The robot's command for giving up when the lean is past recovering"
      ]
    ]

  alias BB.Math.Transform2D
  alias BB.Message
  alias BB.Message.Geometry.Twist2D
  alias BB.Message.Sensor.JointState
  alias BB.NSK.Sensor.Heading
  alias BB.Robot.Runtime
  alias BB.Robot.Units
  alias BB.StateMachine.Transition

  @doc """
  The wheel velocity a lean error and rate call for, in rad/s.

  Positive is forwards, which is the way to move to get back under a forward
  lean, so the proportional term takes the error's sign directly.
  """
  @spec effort(float, float, float, float) :: float
  def effort(error, rate, proportional_gain, derivative_gain) do
    proportional_gain * error + derivative_gain * rate
  end

  @doc """
  The differential wheel velocity a heading error and yaw rate call for, in rad/s.

  Positive turns the robot to its left, which means the right wheel running
  faster than the left. `error` is measured minus held, the same sense as the
  lean loop's, and `rate` is positive turning left.

  **Negated, where `effort/4` is not**, and the asymmetry is real rather than a
  slip. A lean error is corrected by driving *towards* it, because that is how
  the wheels get back under a falling body. A heading error has no such
  inversion: being turned too far left is corrected by turning right.

  Clamped, because wheel velocity spent on heading is velocity unavailable for
  staying upright, and the balance loop already saturates occasionally. A robot
  that drives straight into the floor has not been improved.
  """
  @spec twist(float, float, float, float, float) :: float
  def twist(error, rate, gain, damping, limit) do
    -(gain * error + damping * rate)
    |> max(-limit)
    |> min(limit)
  end

  @doc """
  The trim after a sample, clamped to `limit`.

  A positive command means the robot is driving forwards to hold its lean, so
  the setpoint is too far forward and the trim goes down to lean it back.
  """
  @spec trim(float, float, float, float, float) :: float
  def trim(trim, command, gain, limit, dt) do
    (trim - gain * command * dt)
    |> max(-limit)
    |> min(limit)
  end

  @doc """
  A running average of the wheel command, over `tau` seconds.

  The trim integrates this rather than the command itself. The command is
  dominated by the loop's own oscillation — swinging tens of rad/s either side of
  zero several times a second — and integrating that means the trim chases
  whichever way the last swing went and rails within a second. Averaged over a
  second the oscillation cancels and what is left is the sustained component,
  which is the part that means the robot is going somewhere.
  """
  @spec smooth(float, float, float, float) :: float
  def smooth(average, value, dt, tau) when dt > 0.0 and tau > 0.0 do
    average + (value - average) * min(dt / tau, 1.0)
  end

  def smooth(average, _value, _dt, _tau), do: average

  @doc """
  Whether the wheels are telling the trim anything true about the setpoint.

  Only when nobody is driving and the command is small. The trim exists to notice
  that the robot needs a persistent nudge to stay put and conclude the setpoint is
  wrong — but a hard command means something else is going on, and integrating it
  teaches the trim a lie.

  **Measured, because this was doing real harm.** A shove railed the trim inside a
  second, railed it the other way as the recovery overshot, and left the robot
  balancing against a fully displaced setpoint for the fifteen seconds it took to
  unwind — the command that would unwind it being nearly zero once calm. Two
  shoves, two falls. The separation is clean: calm balancing sits under 0.8 rad/s
  and a shove produces 4 to 18, so a ceiling of 2 lands in empty space.
  """
  @spec learning?(float, float, float) :: boolean
  def learning?(average, drive_lean, ceiling) do
    drive_lean == 0.0 and abs(average) <= ceiling
  end

  @doc """
  Whether the pilot has just let go of the turn, as opposed to never having asked
  for one.

  The distinction matters because the two want opposite things from the held
  heading: a robot that was never turning should keep holding the heading it has,
  and one that has just stopped turning should adopt the heading it actually
  reached — otherwise the lag it built up during the turn is a standing error the
  loop goes on correcting after the thumb comes off, turning it further.

  A zero turn is compared numerically rather than matched, because a negated zero
  deflection is the obvious way to arrive here and `-0.0` does not match `0.0`.
  """
  @spec releasing?(boolean, float) :: boolean
  def releasing?(turning?, turn), do: turning? and turn == 0.0

  @doc """
  Which of the two slew rates this tick calls for.

  `release` while the drive lean is on its way back towards zero, `slew` while it
  is on its way out. The asymmetry is the point: a step in the drive lean is
  answered with `kp` times it, and that kick drives the wheels forward under a
  body still leaning forward — on the way out it is a lurch, and on the way back
  it *is* the deceleration. So the lean is walked out slowly and brought back
  fast, because how quickly letting go stops the robot is what a pilot judges the
  pad on.

  The condition says the step and the lean point opposite ways, which is the same
  thing as the lean shrinking. Decided per tick rather than once per command, so a
  throttle reversed straight through zero is fast down to the balance point and
  slow away from it — the same rule either side rather than a special case.

  Comparing magnitudes instead would get that case wrong: reversing to an equal
  and opposite throttle leaves them equal, and the whole transit would crawl.
  """
  @spec rate(float, float, float, float) :: float
  def rate(target, drive_lean, _slew, release)
      when drive_lean * (target - drive_lean) < 0.0,
      do: release

  def rate(_target, _drive_lean, slew, _release), do: slew

  @doc """
  Whether the robot is being held still enough, and near enough to upright, to
  take over from whoever is holding it.
  """
  @spec catchable?(float, float, float, float) :: boolean
  def catchable?(error, rate, catch_angle, catch_rate) do
    abs(error) <= catch_angle and abs(rate) <= catch_rate
  end

  @doc """
  Which operational state an attitude calls for.

  The one place that decides this, so that the loop and `BB.NSK.Command.Arm`
  cannot come to different conclusions about the same robot.
  """
  @spec classify(float, float, float, float, float) :: :balancing | :fallen | :idle
  def classify(error, rate, fall_angle, catch_angle, catch_rate) do
    cond do
      abs(error) > fall_angle -> :fallen
      catchable?(error, rate, catch_angle, catch_rate) -> :balancing
      true -> :idle
    end
  end

  @doc """
  The state the robot's current attitude calls for, asked of the running loop.

  It knows things a caller doesn't: the trim it has wound on, and the last lean
  the IMU reported. Returns `:idle` if there is no balance controller, which on
  the host there isn't.
  """
  @spec classify(module) :: :balancing | :fallen | :idle
  def classify(robot) do
    case BB.Process.call(robot, :balancer, :classify) do
      state when is_atom(state) -> state
      _no_controller -> :idle
    end
  catch
    :exit, _reason -> :idle
  end

  @doc """
  What the loop has been doing lately, small enough to read.

  A trace is four hundred tuples, which nobody can look at. This is the same
  data as a dozen numbers and a list of things worth knowing, with the angles in
  degrees because that is how people think about leaning.

  `:notes` is the part that matters. It encodes what we have learned to look for
  the hard way — a trim sitting on its clamp, a command that never changes sign,
  saturation — so that reading a trace doesn't depend on remembering which of
  those means what.
  """
  @spec report(module) :: {:ok, map} | {:error, term}
  def report(robot) do
    with {:ok, samples} <- trace(robot),
         {:ok, events} <- BB.Process.call(robot, :balancer, :events) do
      {:ok, report(samples, events)}
    end
  end

  @doc """
  Summarise a trace and a list of events. Split out so it can be tested.
  """
  @spec report([tuple], [tuple]) :: map
  def report([], events), do: %{samples: 0, events: events, notes: ["nothing recorded"]}

  def report(samples, events) do
    degrees = &(&1 * 180 / :math.pi())
    errors = Enum.map(samples, fn {_, _, error, _, _} -> error end)
    commands = Enum.map(samples, fn {_, _, _, command, _} -> command end)
    trims = Enum.map(samples, fn {_, _, _, _, trim} -> trim end)
    {first, last} = {hd(samples), List.last(samples)}

    facts = %{
      samples: length(samples),
      seconds: Float.round(elem(last, 0) - elem(first, 0), 2),
      mean_error: Float.round(degrees.(mean(errors)), 2),
      mean_command: Float.round(mean(commands), 2),
      peak_command: Float.round(Enum.max(Enum.map(commands, &abs/1)), 2),
      trim: Float.round(degrees.(List.last(trims)), 2),
      trim_range:
        {Float.round(degrees.(Enum.min(trims)), 2), Float.round(degrees.(Enum.max(trims)), 2)},
      period: period(samples),
      events: events
    }

    Map.put(facts, :notes, notes(facts))
  end

  # Everything this session taught us about reading one of these, so that nobody
  # has to hold it in their head at the time it matters.
  defp notes(facts) do
    [
      if(abs(facts.mean_command) > 2.0,
        do:
          "driving steadily #{if facts.mean_command > 0, do: "forwards", else: "backwards"} " <>
            "at #{facts.mean_command} rad/s — the setpoint is wrong, or the trim hasn't caught up"
      ),
      if(abs(facts.mean_error) > 1.0,
        do:
          "sitting #{facts.mean_error} degrees off the setpoint on average, which a PD loop " <>
            "does when the setpoint isn't where the robot can actually stand"
      ),
      if(facts.period,
        do:
          "oscillating with a period of #{Float.round(facts.period, 3)}s — " <>
            "a derivative gain of kp * #{Float.round(facts.period / 8, 4)} suits that"
      ),
      if(facts.peak_command >= 31.0,
        do: "the command is saturating, so some of what the loop asked for never happened"
      ),
      trim_note(facts)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # The clamp first: a pinned trim is also a trim that has stopped moving, and
  # "it has barely moved" is exactly the wrong thing to say about one that spent
  # the whole trace asking for more than it was allowed.
  defp trim_note(%{trim: trim}) when abs(trim) >= 4.9,
    do:
      "the trim is on its clamp — it is asking for more correction than it is allowed, " <>
        "which means the setpoint is further away than measurement error explains"

  defp trim_note(%{trim_range: {low, high}}) when high - low < 0.05,
    do: "the trim has barely moved, so it is not what is holding this back"

  defp trim_note(_facts), do: nil

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)

  @doc """
  The last few seconds of the loop, oldest first.

  Each sample is `{seconds_ago, lean, error, command, trim}`, with the angles in
  radians and the command in rad/s of wheel velocity. Gains are found by
  watching these rather than by watching the robot: a fall tells you it went
  wrong, the trace tells you how.
  """
  @spec trace(module) :: {:ok, [tuple]} | {:error, term}
  def trace(robot), do: BB.Process.call(robot, :balancer, :trace)

  @doc """
  How long the loop is taking to swing back and forth, in seconds.

  Counts crossings of the *mean* lean error across a trace and halves the mean
  interval between them. That is the period a `kd` should be set from — Ziegler
  and Nichols put it at `kp * period / 8` — and eyeballing a wobbling robot will
  not give it to you.

  **Crossings of the mean, not of zero.** A robot whose setpoint is wrong wobbles
  about a lean it shouldn't be holding, so the error oscillates without ever
  changing sign, and counting zero crossings there measures whatever the trace
  was doing either side of the oscillation instead.

  **The median interval, not the mean.** A real trace is not a clean sine: it
  covers wobbling, falling and being picked up, and noise near the mean throws
  extra crossings. On the robot the intervals ran from 0.015 to 0.624 seconds,
  so the mean answered 0.299 for a wobble the median and the peaks both put at
  0.13. Since a derivative gain comes straight out of this number, the
  difference is a factor of two in the gain most likely to be causing the
  oscillation in the first place.

  Narrow the trace to a window that is actually oscillating before trusting it;
  four seconds of a robot's life is rarely one regime.

  `nil` when the error doesn't cross its own mean twice, which means there is no
  oscillation to measure.
  """
  @spec period([tuple]) :: float | nil
  def period([]), do: nil

  def period(samples) do
    mean = Enum.sum(Enum.map(samples, fn {_, _, error, _, _} -> error end)) / length(samples)

    samples
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [{_, _, a, _, _}, {_, _, b, _, _}] -> (a - mean) * (b - mean) < 0 end)
    |> Enum.map(fn [_previous, {at, _, _, _, _}] -> at end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [before, after_] -> after_ - before end)
    |> median()
    |> case do
      nil -> nil
      half -> 2 * half
    end
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)

    Enum.at(sorted, div(length(sorted), 2))
  end

  @impl BB.Controller
  def init(opts) do
    %{robot: robot} = Keyword.fetch!(opts, :bb)

    {:ok, _subscription} = BB.PubSub.subscribe(robot, [:state_machine])
    {:ok, _subscription} = BB.PubSub.subscribe(robot, lean_path(robot, opts))
    {:ok, _subscription} = BB.PubSub.subscribe(robot, heading_path(robot, opts))
    {:ok, _subscription} = BB.PubSub.subscribe(robot, BB.NSK.Drive.path())

    {:ok,
     configure(
       opts,
       %{
         robot: robot,
         mode: Runtime.state(robot),
         trim: 0.0,
         last: nil,
         lean: nil,
         rate: 0.0,
         average_command: 0.0,
         heading: nil,
         yaw_rate: 0.0,
         hold: nil,
         drive: {0.0, 0.0},
         drive_at: nil,
         drive_lean: 0.0,
         turning?: false,
         trace: [],
         events: []
       }
     )}
  end

  @impl BB.Controller
  def handle_options(opts, state), do: {:ok, configure(opts, state)}

  @impl BB.Controller
  def handle_call(:events, _from, state) do
    now = System.monotonic_time(:nanosecond)

    events =
      state.events
      |> Enum.reverse()
      |> Enum.map(fn {at, from, to} -> {Float.round((at - now) / 1_000_000_000, 2), from, to} end)

    {:reply, {:ok, events}, state}
  end

  def handle_call(:classify, _from, state) do
    {:reply, classify_state(state), state}
  end

  def handle_call(:trace, _from, state) do
    now = System.monotonic_time(:nanosecond)

    samples =
      state.trace
      |> Enum.reverse()
      |> Enum.map(fn {at, lean, error, command, trim} ->
        {(at - now) / 1_000_000_000, lean, error, command, trim}
      end)

    {:reply, {:ok, samples}, state}
  end

  @impl BB.Controller
  def handle_info(
        {:bb, [:state_machine], %Message{payload: %Transition{from: from, to: to}}},
        state
      ) do
    events = Enum.take([{System.monotonic_time(:nanosecond), from, to} | state.events], 20)

    # Taking over means holding the heading it is being handed at, not whatever
    # it was pointing at last time. The trim carrying between attempts confounded
    # a whole evening of measurement; this does not repeat that.
    {:noreply,
     %{
       state
       | mode: to,
         last: nil,
         average_command: 0.0,
         hold: hold_for(to, state),
         events: events
     }}
  end

  # The heading sensor reports a `:planar` joint, so its configuration is a whole
  # `Transform2D` where the lean's is a float. Matched on shape and ahead of the
  # lean clause, which would otherwise take this for a lean sample and drive the
  # wheels from a heading.
  def handle_info(
        {:bb, _path,
         %Message{
           payload: %JointState{
             positions: [%Transform2D{theta: heading}],
             velocities: [%Twist2D{omega: yaw_rate}]
           }
         }},
        state
      ) do
    {:noreply, %{state | heading: heading, yaw_rate: yaw_rate}}
  end

  # A bare `Twist2D`, where the heading arrives wrapped in a `JointState`, so the
  # two cannot be confused for each other.
  def handle_info(
        {:bb, _path, %Message{payload: %BB.NSK.Message.Drive{throttle: throttle, turn: turn}}},
        state
      ) do
    {:noreply, %{state | drive: {throttle, turn}, drive_at: System.monotonic_time(:nanosecond)}}
  end

  def handle_info(
        {:bb, _path,
         %Message{payload: %JointState{positions: [lean], velocities: [rate]}} = message},
        state
      )
      when is_float(lean) and is_float(rate) do
    {:noreply, step(state, lean, rate, message.monotonic_time)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A lean sample is the loop's tick, so everything happens here: decide whether
  # the robot should be balancing at all, and if it is, drive the wheels.
  defp step(state, lean, rate, now) do
    # Recorded whatever the mode, because `classify/1` is asked for this from
    # outside — by the arm command, before the loop is running at all.
    # The throttle is a lean the pilot has asked for on top of the balance point.
    # Leaning is how a balance bot accelerates, so this *is* the drive — there is
    # no separate speed to command, and the error the loop chases is simply
    # measured against a target the pilot has moved.
    #
    # Slewed before it is used, so a thumb slammed to the edge of the pad ramps
    # rather than steps.
    state = %{state | lean: lean, rate: rate, drive_lean: slew(state, now)}

    # `classify/1` reads this through the state, so a robot leaned hard enough to
    # fall while being driven falls rather than being described as upright.
    error = lean - (state.setpoint + state.trim + state.drive_lean)

    case state.mode do
      :balancing -> balance(state, error, rate, now)
      :idle -> settle(state, error, rate)
      :fallen -> maybe_catch(state, error, rate)
      _other -> state
    end
  end

  # Arming lands in `:idle` whatever attitude the robot is in, so a robot armed
  # while lying on its side would sit there calling itself idle — and looking,
  # from the NeoPixels, exactly like one standing ready. It decides for itself
  # on the first sample instead, which leaves `:idle` meaning what it says: armed,
  # upright enough to be worth catching, and not yet still enough to catch.
  defp settle(state, error, rate) do
    case classify(error, rate, state.fall_angle, state.catch_angle, state.catch_rate) do
      :fallen -> fall(state)
      :balancing -> stand(state)
      :idle -> state
    end
  end

  # What the robot's last known attitude calls for. Nil until a sample arrives,
  # which is a robot that has told us nothing, so leave it where it is.
  defp classify_state(%{lean: nil}), do: :idle

  defp classify_state(state) do
    classify(
      state.lean - (state.setpoint + state.trim),
      state.rate,
      state.fall_angle,
      state.catch_angle,
      state.catch_rate
    )
  end

  defp balance(state, error, rate, now) do
    if abs(error) > state.fall_angle do
      fall(state)
    else
      command = effort(error, rate, state.proportional_gain, state.derivative_gain)
      differential = differential(state)

      BB.Actuator.set_velocity(state.robot, state.left_wheel, command - differential)
      BB.Actuator.set_velocity(state.robot, state.right_wheel, command + differential)

      state = record(state, now, error + state.setpoint + state.trim, error, command)
      dt = dt(state, now)
      average = smooth(state.average_command, command, dt, state.trim_tau)
      {_throttle, turn} = drive(state, now)

      %{
        state
        | trim: retrim(state, average, dt),
          average_command: average,
          hold: follow(state, turn, dt),
          turning?: turn != 0.0,
          last: now
      }
    end
  end

  defp maybe_catch(state, error, rate) do
    if catchable?(error, rate, state.catch_angle, state.catch_rate) do
      stand(state)
    else
      state
    end
  end

  defp stand(state) do
    apply(state.robot, state.stand_command, [])

    state
  end

  defp fall(state) do
    # Braked rather than coasting, so it doesn't roll off the bench while it
    # waits. The transition is what tells the operator, through the panel and
    # the NeoPixels, that it is safe to pick up.
    Enum.each([state.left_wheel, state.right_wheel], &BB.Actuator.hold(state.robot, &1))
    apply(state.robot, state.fall_command, [])

    # `:fallen` here rather than waiting for the transition to come back around
    # through pubsub. A command is a process to spawn and a state machine to
    # round-trip, and every lean sample arriving in the meantime would find this
    # still saying `:balancing` and drive the wheels again — over the brake that
    # was just applied, at whatever the last error asked for, which just before
    # a fall is full speed.
    %{state | mode: :fallen, last: nil}
  end

  # Nothing to correct until a heading has arrived and one has been held. On the
  # host neither ever does, since the IMU that feeds the heading only exists on
  # target, so this is also what keeps the loop driving straight there.
  defp differential(%{heading: nil}), do: 0.0
  defp differential(%{hold: nil}), do: 0.0

  defp differential(state) do
    twist(
      Heading.difference(state.heading, state.hold),
      state.yaw_rate,
      state.yaw_gain,
      state.yaw_damping,
      state.yaw_limit
    )
  end

  # The held heading follows the measured one, slowly. It has to: there is no
  # magnetometer, so the heading integrates gyro bias at around 20 degrees a
  # minute, and a setpoint that ignored that would wind on a standing correction
  # and turn the robot in a slow circle.
  #
  # The cost is that this holds a *recent* heading rather than a fixed one, so a
  # disturbance is corrected only to the extent it happens faster than `yaw_tau`.
  # That is the whole of what a gyro without a compass can offer, and it is what
  # rejecting a twist from the terrain actually needs.
  defp follow(%{hold: nil} = state, _turn, _dt), do: state.heading
  defp follow(%{heading: nil} = state, _turn, _dt), do: state.hold

  defp follow(state, turn, dt) do
    # **Letting go of the turn snaps the held heading to where the robot actually
    # is.** The robot lags a commanded turn — by about ten degrees once
    # `yaw_limit` binds, and without bound if the rate asked for is more than the
    # wheels can deliver — and that lag is a standing error the loop would go on
    # correcting after the thumb came off, turning the robot further, and for
    # longer the harder it had been turning. Snapping zeroes it on the same
    # sample, so releasing means holding *here* rather than finishing the turn.
    #
    # Nothing is given up by it. The heading hold's job after a turn is to keep
    # the heading the pilot turned to, not the one the command walked off to.
    if releasing?(state.turning?, turn) do
      state.heading
    else
      # Turning is the held heading being walked round at the commanded rate, so
      # the yaw loop chases a moving target and letting go leaves it holding
      # wherever it got to. Steering by moving the setpoint rather than by adding
      # a differential means the turn is closed-loop like everything else, and a
      # wheel slipping mid-turn is corrected rather than quietly costing heading.
      Heading.wrap(
        state.hold + turn * dt +
          smooth(0.0, Heading.difference(state.heading, state.hold), dt, state.yaw_tau)
      )
    end
  end

  # Both axes decay to nothing when the pilot goes quiet, whether that is a
  # finger lifted or a phone out of range. `drive_at` is nil until the first
  # command ever arrives.
  defp drive(%{drive_at: nil}, _now), do: {0.0, 0.0}

  defp drive(state, now) do
    if now - state.drive_at <= state.drive_timeout do
      state.drive
    else
      {0.0, 0.0}
    end
  end

  # Walks towards what the pilot asked, rather than jumping, at whichever of the
  # two rates `rate/4` says this tick calls for.
  #
  # `dt` is capped because it comes from message timestamps and is reset to zero
  # on a transition — an uncapped one after a pause would let the lean arrive in
  # a single sample, which is the step this exists to avoid.
  defp slew(state, now) do
    {throttle, _turn} = drive(state, now)
    target = throttle * state.drive_limit
    slew_rate = rate(target, state.drive_lean, state.drive_slew, state.drive_release)
    step = slew_rate * min(dt(state, now), 0.1)

    cond do
      target > state.drive_lean -> min(state.drive_lean + step, target)
      target < state.drive_lean -> max(state.drive_lean - step, target)
      true -> target
    end
  end

  # **The trim is frozen while somebody is driving.** It exists to notice a
  # sustained wheel command and conclude the setpoint is wrong, and a pilot
  # holding the throttle produces exactly that — so left running it would spend a
  # few seconds quietly trimming the steering away, and then a few more winding
  # back when the throttle was released.
  #
  # Nothing is lost by the pause. The trim corrects a bias that moves with the
  # centre of mass, which does not change over the seconds a drive lasts.
  defp retrim(state, average, dt) do
    if learning?(average, state.drive_lean, state.trim_ceiling) do
      trim(state.trim, average, state.trim_gain, state.trim_limit, dt)
    else
      state.trim
    end
  end

  # Only `:balancing` holds a heading. Anything else is a robot being carried,
  # picked up or lying down, and the heading it had then is not worth keeping.
  defp hold_for(:balancing, state), do: state.heading
  defp hold_for(_mode, _state), do: nil

  # The first sample after a transition has no predecessor to measure against,
  # and a stale one would hand the trim a huge interval.
  defp dt(%{last: nil}, _now), do: 0.0
  defp dt(%{last: last}, now), do: (now - last) / 1_000_000_000

  # Merged rather than updated, because `init/1` builds the state around this
  # and has none of these keys yet.
  # Newest first, so keeping the last N is a take rather than a walk to the end.
  defp record(%{trace_samples: 0} = state, _now, _lean, _error, _command), do: state

  defp record(state, now, lean, error, command) do
    %{
      state
      | trace:
          Enum.take([{now, lean, error, command, state.trim} | state.trace], state.trace_samples)
    }
  end

  defp configure(opts, state) do
    Map.merge(state, %{
      setpoint: radians(Keyword.fetch!(opts, :setpoint)),
      proportional_gain: Keyword.fetch!(opts, :proportional_gain),
      derivative_gain: Keyword.fetch!(opts, :derivative_gain),
      trim_gain: Keyword.fetch!(opts, :trim_gain),
      trim_limit: radians(Keyword.fetch!(opts, :trim_limit)),
      fall_angle: radians(Keyword.fetch!(opts, :fall_angle)),
      catch_angle: radians(Keyword.fetch!(opts, :catch_angle)),
      catch_rate: convert(Keyword.fetch!(opts, :catch_rate), "radian-per-second"),
      left_wheel: Keyword.fetch!(opts, :left_wheel),
      right_wheel: Keyword.fetch!(opts, :right_wheel),
      yaw_gain: Keyword.fetch!(opts, :yaw_gain),
      yaw_damping: Keyword.fetch!(opts, :yaw_damping),
      yaw_limit: Keyword.fetch!(opts, :yaw_limit),
      yaw_tau: Keyword.fetch!(opts, :yaw_tau),
      # Nanoseconds, because that is what the loop's timestamps are in and
      # converting once here beats converting on every sample.
      drive_timeout: Keyword.fetch!(opts, :drive_timeout) * 1_000_000,
      drive_limit: radians(Keyword.fetch!(opts, :drive_limit)),
      drive_slew: convert(Keyword.fetch!(opts, :drive_slew), "radian-per-second"),
      drive_release: convert(Keyword.fetch!(opts, :drive_release), "radian-per-second"),
      trim_tau: Keyword.fetch!(opts, :trim_tau),
      trim_ceiling: Keyword.fetch!(opts, :trim_ceiling),
      trace_samples: Keyword.fetch!(opts, :trace_samples),
      stand_command: Keyword.fetch!(opts, :stand_command),
      fall_command: Keyword.fetch!(opts, :fall_command)
    })
  end

  defp radians(unit), do: convert(unit, "radian")

  defp convert(unit, to) do
    unit
    |> Localize.Unit.convert!(to)
    |> Units.extract_float()
  end

  defp lean_path(robot, opts) do
    {:ok, joint_path} = BB.Robot.path_to(robot.robot(), Keyword.fetch!(opts, :lean_joint))

    [:sensor | joint_path] ++ [Keyword.fetch!(opts, :lean_sensor)]
  end

  defp heading_path(robot, opts) do
    {:ok, joint_path} = BB.Robot.path_to(robot.robot(), Keyword.fetch!(opts, :heading_joint))

    [:sensor | joint_path] ++ [Keyword.fetch!(opts, :heading_sensor)]
  end
end
