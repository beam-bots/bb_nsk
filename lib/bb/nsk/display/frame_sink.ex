# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

# The panel's rendering stack needs `emerge`, which is an optional dependency —
# a robot that only balances has no business pulling a Skia NIF into its
# firmware. `bb_nsk.add_display` adds it, and then these compile.
if Code.ensure_loaded?(VideoInterop.Frame) do
  defmodule BB.NSK.Display.FrameSink do
    @moduledoc """
    Takes packed frames off the renderer and puts them on the panel.

    `BB.NSK.Display.Viewport` renders into this process, which receives
    `{:emerge_skia_frame, %VideoInterop.Frame{}}` messages carrying a frame
    already packed to the panel's format. Nothing here converts pixels.

    A refresh takes seconds and the renderer can produce frames faster than that,
    so drawing happens in a spawned process and only the *latest* frame waits: a
    burst of renders costs one refresh of the last one rather than a queue of
    stale ones. That matters because the robot's safety state can change several
    times inside a single refresh.

    **Emerge sends nothing at all when a screen renders to an unchanged tree**,
    which is most of the deduplication and it happens before any of this. What is
    left here catches the rarer case of two different trees packing to the same
    bytes, such as a change that lands where the layout clips it.

    That upstream silence is also a trap, and `configure/3` works around it. A
    full refresh is asked for when the panel needs clearing rather than when the
    picture changed — it is what removes the ghosting partial refreshes leave —
    so it is exactly the case where the tree is most likely to be identical and
    no frame will arrive. Asking for one therefore arms a timer, and if nothing
    has been rendered by the time it fires the retained frame is redrawn instead.
    Without that, a panel showing an unchanging screen would never be cleaned up,
    and `BB.NSK.Display.Controller.refresh/1` would silently do nothing.

    On the host there is no panel, so the draw function is a no-op and the sink
    is a place to read the last frame from — which is how a screen is previewed
    without hardware.
    """

    use GenServer

    alias BB.NSK.Display
    alias VideoInterop.{Binary, Frame}
    alias VideoInterop.Binary.Plane

    require Logger

    @doc """
    Set the mode the next frames will arrive in, and how the panel should refresh.

    The renderer is told the mode separately, when the viewport mounts, so this
    is what the sink validates arriving frames against.
    """
    @spec configure(GenServer.server(), :bw1 | :gray2, :full | :partial) :: :ok
    def configure(server \\ __MODULE__, mode, refresh_type) do
      GenServer.call(server, {:configure, mode, refresh_type})
    end

    @doc """
    Redraw the frame already on the panel.

    Nothing is rendered — these are the bytes the panel was last sent — so this
    is how a screen that has not changed still gets its ghosting cleared.
    """
    @spec redraw(GenServer.server(), :full | :partial) :: :ok
    def redraw(server \\ __MODULE__, refresh_type) do
      GenServer.call(server, {:redraw, refresh_type})
    end

    @doc """
    The last frame the renderer produced, packed exactly as the panel receives it.
    """
    @spec current_frame(GenServer.server()) :: binary | nil
    def current_frame(server \\ __MODULE__) do
      GenServer.call(server, :current_frame, :timer.seconds(30))
    end

    @doc """
    How many frames the renderer has delivered.

    Counts frames arriving, not refreshes: an unchanged screen still renders, and
    the panel is spared the draw rather than the renderer being spared the work.
    A count that stops climbing while the screen is being changed means the
    renderer has stopped, which is otherwise invisible from this end.
    """
    @spec frames(GenServer.server()) :: non_neg_integer
    def frames(server \\ __MODULE__) do
      GenServer.call(server, :frames)
    end

    @doc """
    Blank the panel.

    Waits for any refresh already under way, so that this is the last thing the
    panel is told rather than a command it drops on its way out.
    """
    @spec clear(GenServer.server()) :: :ok | {:error, term}
    def clear(server \\ __MODULE__) do
      GenServer.call(server, :clear, :timer.seconds(30))
    end

    @spec start_link(keyword) :: GenServer.on_start()
    def start_link(opts) do
      {genserver_opts, init_opts} = Keyword.split(opts, [:name])
      GenServer.start_link(__MODULE__, init_opts, genserver_opts)
    end

    @impl GenServer
    def init(opts) do
      {:ok,
       %{
         draw: Keyword.fetch!(opts, :draw),
         clear: Keyword.get(opts, :clear, fn -> :ok end),
         render_grace: Keyword.get(opts, :render_grace, :timer.seconds(2)),
         grace_timer: nil,
         drawing: nil,
         latest: :none,
         mode: Keyword.get(opts, :mode, :bw1),
         refresh_type: :full,
         frame: nil,
         frames: 0
       }}
    end

    @impl GenServer
    def handle_call({:configure, mode, refresh_type}, _from, state) do
      {:reply, :ok, arm(%{state | mode: mode, refresh_type: refresh_type})}
    end

    def handle_call({:redraw, refresh_type}, _from, state) do
      {:reply, :ok, force(%{state | refresh_type: refresh_type})}
    end

    def handle_call(:current_frame, _from, state), do: {:reply, state.frame, state}

    def handle_call(:frames, _from, state), do: {:reply, state.frames, state}

    def handle_call(:clear, _from, state) do
      {:reply, state.clear.(), state}
    end

    @impl GenServer
    def handle_info({:emerge_skia_frame, %Frame{} = video_frame}, state) do
      case packed(video_frame, Display.mode(state.mode)) do
        {:ok, data} ->
          {:noreply, accept(data, disarm(state))}

        {:error, reason} ->
          Logger.warning("Ignoring a headless frame that is not the panel's: #{reason}")
          {:noreply, state}
      end
    end

    def handle_info(:render_grace_expired, state) do
      {:noreply, force(%{state | grace_timer: nil})}
    end

    def handle_info({:draw_complete, pid, result}, %{drawing: {pid, monitor}} = state) do
      Process.demonitor(monitor, [:flush])
      log(result)
      {:noreply, start_latest(%{state | drawing: nil})}
    end

    def handle_info({:DOWN, monitor, :process, pid, reason}, %{drawing: {pid, monitor}} = state) do
      Logger.error("The panel's draw process exited: #{inspect(reason)}")
      {:noreply, start_latest(%{state | drawing: nil})}
    end

    def handle_info(_message, state), do: {:noreply, state}

    @impl GenServer
    def terminate(_reason, %{drawing: {pid, monitor}}) do
      Process.demonitor(monitor, [:flush])
      Process.exit(pid, :shutdown)
      :ok
    end

    def terminate(_reason, _state), do: :ok

    defp accept(data, state) do
      drawing? = draw?(data, state)
      state = %{state | frame: data, frames: state.frames + 1}

      if drawing? do
        queue(%{data: data, palette: Display.mode(state.mode).palette}, state)
      else
        state
      end
    end

    # A full refresh is asked for when the panel needs clearing rather than when
    # the picture changed, so it goes ahead whatever the bytes say.
    defp draw?(_data, %{refresh_type: :full}), do: true
    defp draw?(data, %{frame: data}), do: false
    defp draw?(_data, _state), do: true

    # Only a full refresh is worth waiting for. A partial one that renders to
    # nothing new has nothing to say to the panel.
    defp arm(%{refresh_type: :full, frame: frame} = state) when not is_nil(frame) do
      state = disarm(state)

      %{
        state
        | grace_timer: Process.send_after(self(), :render_grace_expired, state.render_grace)
      }
    end

    defp arm(state), do: disarm(state)

    defp disarm(%{grace_timer: nil} = state), do: state

    defp disarm(state) do
      Process.cancel_timer(state.grace_timer)
      %{state | grace_timer: nil}
    end

    defp force(%{frame: nil} = state), do: state

    defp force(state) do
      queue(%{data: state.frame, palette: Display.mode(state.mode).palette}, state)
    end

    defp queue(frame, %{drawing: nil} = state), do: start(frame, state)
    defp queue(frame, state), do: %{state | latest: {:some, frame}}

    defp start(frame, state) do
      owner = self()
      draw = state.draw
      refresh_type = state.refresh_type

      {pid, monitor} =
        spawn_monitor(fn ->
          send(owner, {:draw_complete, self(), draw.(frame, refresh_type)})
        end)

      %{state | drawing: {pid, monitor}, latest: :none}
    end

    defp start_latest(%{latest: :none} = state), do: state

    defp start_latest(%{latest: {:some, frame}} = state) do
      start(frame, %{state | latest: :none})
    end

    defp packed(
           %Frame{
             coded_width: width,
             coded_height: height,
             format: %{storage: %{pixel_format: pixel_format, bw1_polarity: polarity}},
             storage: %Binary{data: data, planes: [%Plane{stride: stride}]}
           } = video_frame,
           profile
         ) do
      {panel_width, panel_height} = Display.size()

      checks = [
        {VideoInterop.validate(video_frame) == :ok, "the frame did not validate"},
        {pixel_format == profile.pixel_format, "pixel format #{inspect(pixel_format)}"},
        {polarity == profile.bw1_polarity, "polarity #{inspect(polarity)}"},
        {width == panel_width and height == panel_height, "size #{width}x#{height}"},
        {stride == profile.stride_bytes, "stride #{stride}"},
        {byte_size(data) == profile.frame_bytes, "#{byte_size(data)} bytes"}
      ]

      case Enum.find(checks, &match?({false, _reason}, &1)) do
        nil -> {:ok, data}
        {false, reason} -> {:error, reason}
      end
    end

    defp packed(_video_frame, _profile), do: {:error, "not a packed binary frame"}

    defp log(:ok), do: :ok
    defp log({:error, reason}), do: Logger.error("The panel refused a frame: #{inspect(reason)}")
    defp log(other), do: Logger.warning("Unexpected result drawing a frame: #{inspect(other)}")
  end
end
