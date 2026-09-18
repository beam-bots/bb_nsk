# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Display.Controller do
  @moduledoc """
  Decides when the panel is redrawn, and with what.

  It owns none of the panel: `BB.NSK.Display.Viewport` renders and
  `BB.NSK.Display.FrameSink` draws. What lives here is the policy, which is
  the part that is specific to this robot.

  A refresh takes seconds, so redraws are driven by change rather than by a
  clock: the controller watches the robot's safety state and the WiFi
  interface, and coalesces a burst of changes into one redraw. A
  slower periodic redraw keeps uptime, memory and load from going stale and
  does the full refresh that clears the ghosting partial refreshes leave
  behind.

  Arbitrary screens can be drawn over the top with `render/3`; the next redraw
  replaces them.

  When there is no viewport — on the host, or if the renderer failed to start —
  the controller runs anyway and its redraws go nowhere. That keeps the robot's
  topology the same everywhere rather than making an entity conditional on
  hardware.
  """

  use BB.Controller,
    options_schema: [
      viewport: [
        type: :atom,
        default: BB.NSK.Display.Viewport,
        doc: "The Emerge viewport that renders screens"
      ],
      frame_sink: [
        type: :atom,
        default: BB.NSK.Display.FrameSink,
        doc: "The process that puts rendered frames on the panel"
      ],
      mode: [
        type: {:in, [:bw1, :gray2]},
        default: :bw1,
        doc: "Whether the panel is driven one bit per pixel or two"
      ],
      settle: [
        type: :timeout,
        default: :timer.seconds(2),
        doc: "How long to wait for changes to stop arriving before redrawing"
      ],
      refresh_interval: [
        type: :timeout,
        default: :timer.minutes(5),
        doc: "How often to redraw regardless of changes, with a full refresh"
      ],
      clear_on_shutdown: [
        type: :boolean,
        default: true,
        doc: "Whether to blank the panel when the robot shuts down"
      ]
    ]

  alias BB.{Message, PubSub}
  alias BB.NSK.Display.{FrameSink, Viewport}
  alias BB.NSK.Message.EnvironmentState
  alias BB.NSK.Status
  alias BB.StateMachine.Transition

  # VintageNet is only built for the target, where this controller runs.
  # The renderer and the sink are guarded on `emerge` being present, and this is
  # not — it is policy, and policy compiles anywhere. A project reaches these
  # only by declaring the panel, which is what puts `emerge` in its `mix.exs`.
  @compile {:no_warn_undefined, [VintageNet, FrameSink, Viewport]}

  @wlan "wlan0"

  @doc """
  Draw a screen onto the panel.

  Takes an `Emerge` tree the size of the panel. The frame reaches the panel
  some time after this returns — rendering is a push, and the panel takes
  seconds — so this reports that the screen was accepted, not that it is up.
  """
  @spec render(module, Emerge.tree(), keyword) :: :ok
  def render(robot, screen, opts \\ []) do
    BB.Process.call(robot, :display, {:render, screen, opts}, :infinity)
  end

  @doc """
  Redraw the dashboard now, without waiting for a change.
  """
  @spec refresh(module) :: :ok
  def refresh(robot) do
    BB.Process.call(robot, :display, :refresh, :infinity)
  end

  @impl BB.Controller
  def init(opts) do
    %{robot: robot} = Keyword.fetch!(opts, :bb)

    # An e-paper panel keeps its last image with no power behind it, so without
    # this the robot leaves a stale dashboard on screen after it has gone.
    # `terminate/2` only runs if we ask for exit signals as messages.
    Process.flag(:trap_exit, true)

    {:ok, _subscription} = PubSub.subscribe(robot, [:state_machine])
    # Subscribe to the one sensor this cares about rather than the whole
    # `[:sensor]` subtree, which would also deliver the IMU's hundred messages a
    # second only for the catch-all below to drop them.
    {:ok, _subscription} = PubSub.subscribe(robot, [:sensor, :environment])
    subscribe_to_network()

    :timer.send_interval(Keyword.fetch!(opts, :refresh_interval), :periodic)

    state = %{
      environment: nil,
      robot: robot,
      viewport: Keyword.fetch!(opts, :viewport),
      frame_sink: Keyword.fetch!(opts, :frame_sink),
      mode: Keyword.fetch!(opts, :mode),
      clear_on_shutdown: Keyword.fetch!(opts, :clear_on_shutdown),
      settle: Keyword.fetch!(opts, :settle),
      settle_timer: nil
    }

    {:ok, state, {:continue, :redraw}}
  end

  @impl BB.Controller
  def handle_continue(:redraw, state), do: {:noreply, redraw(state, :full)}

  @impl BB.Controller
  def handle_call(:refresh, _from, state) do
    {:reply, :ok, redraw(state, :full)}
  end

  def handle_call({:render, screen, opts}, _from, state) do
    {:reply, show(state, screen, Keyword.get(opts, :refresh_type, :partial)), state}
  end

  @impl BB.Controller
  def handle_info({:bb, _path, %Message{payload: %Transition{}}}, state) do
    {:noreply, settle(state)}
  end

  # Room temperature drifting by a tenth of a degree is not worth a refresh, so
  # this is kept for the next redraw rather than causing one.
  def handle_info({:bb, _path, %Message{payload: %EnvironmentState{} = environment}}, state) do
    {:noreply, %{state | environment: environment}}
  end

  def handle_info({VintageNet, _property, _old, _new, _meta}, state) do
    {:noreply, settle(state)}
  end

  def handle_info(:settled, state) do
    {:noreply, redraw(%{state | settle_timer: nil}, :partial)}
  end

  def handle_info(:periodic, state) do
    {:noreply, redraw(state, :full)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl BB.Controller
  def terminate(_reason, %{clear_on_shutdown: true} = state) do
    if Process.whereis(state.frame_sink), do: FrameSink.clear(state.frame_sink)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp subscribe_to_network do
    if Code.ensure_loaded?(VintageNet) do
      VintageNet.subscribe(["interface", @wlan])
    end

    :ok
  end

  # Restart the timer on every change so that a burst of them, such as an
  # interface coming up, costs one refresh rather than one each.
  defp settle(%{settle_timer: nil} = state) do
    %{state | settle_timer: Process.send_after(self(), :settled, state.settle)}
  end

  defp settle(state) do
    Process.cancel_timer(state.settle_timer)

    %{state | settle_timer: Process.send_after(self(), :settled, state.settle)}
  end

  defp redraw(state, refresh_type) do
    status =
      state.robot
      |> Status.snapshot()
      |> put_environment(state.environment)

    show(state, status, refresh_type)

    state
  end

  # The sink is told how to refresh before the screen is handed over, so that
  # the frame it eventually receives is already paired with the right refresh.
  defp show(state, screen, refresh_type) do
    if Process.whereis(state.frame_sink) do
      :ok = FrameSink.configure(state.frame_sink, state.mode, refresh_type)
    end

    if Process.whereis(state.viewport) do
      Viewport.show(state.viewport, screen)
    end

    :ok
  end

  defp put_environment(status, nil), do: status

  defp put_environment(status, environment) do
    %{status | temperature_c: environment.temperature, humidity_percent: environment.humidity}
  end
end
