# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

# The panel's rendering stack needs `emerge`, which is an optional dependency —
# a robot that only balances has no business pulling a Skia NIF into its
# firmware. `bb_nsk.add_display` adds it, and then these compile.
if Code.ensure_loaded?(Emerge) do
  defmodule BB.NSK.Display.Viewport do
    @moduledoc """
    The Emerge renderer behind the panel.

    Holds the last `BB.NSK.Status` it was shown and renders
    `BB.NSK.Display.Dashboard` from it, into `BB.NSK.Display.FrameSink` as a
    packed frame. Arbitrary screens can be put up with `show/2`, which is what
    `BB.NSK.Display.TestCard` uses; the next status update replaces them.

    Rendering is a push: `show/2` hands over a screen and returns, and the frame
    arrives at the sink some time later. Nothing here waits for the panel, which
    takes seconds — `BB.NSK.Display.Controller` decides *when* to redraw and the
    sink decides what reaches the panel.

    The renderer runs on the host too, with no panel behind it, so a screen can be
    previewed without hardware.
    """

    use Emerge

    alias BB.NSK.Display
    alias BB.NSK.Display.Dashboard
    alias BB.NSK.Status
    alias Emerge.Runtime.Viewport, as: Renderer

    @doc """
    Render a status, or any screen, and send the frame to the sink.
    """
    @spec show(GenServer.server(), Status.t() | Emerge.tree()) :: :ok
    def show(viewport \\ __MODULE__, screen) do
      send(viewport, {:show, screen})
      :ok
    end

    @impl Viewport
    def mount(opts) do
      {width, height} = Display.size()
      profile = Display.mode(Keyword.get(opts, :mode, :bw1))
      # Emerge insists on a live local pid for a headless target and will not
      # take a registered name, so the sink is resolved here. The display
      # supervisor restarts this process whenever the sink restarts, which is
      # what keeps that pid from going stale.
      sink = sink_pid(Keyword.fetch!(opts, :sink))

      state = %{
        screen: %Status{},
        upside_down: Keyword.get(opts, :upside_down, true)
      }

      {:ok, state,
       [
         otp_app: :goatzen,
         backend: :headless,
         rendering_api: :raster,
         width: width,
         height: height,
         # The screen changes a handful of times a minute at most and every draw
         # is a fresh tree, so a paint layer cache would only ever be paid for.
         renderer_cache: [enabled: false],
         assets: [fonts: Display.fonts()],
         headless: [
           target: sink,
           mode: :binary,
           pixel_format: profile.pixel_format,
           bw1_polarity: profile.bw1_polarity,
           dither: profile.dither
         ]
       ]}
    end

    @impl Viewport
    def render(%{screen: %Status{} = status} = state) do
      status |> Dashboard.screen() |> Display.paper(state.upside_down)
    end

    def render(state), do: Display.paper(state.screen, state.upside_down)

    # A viewport dispatches `handle_info/2` and has no `handle_cast/2` of its own,
    # so a screen arrives as an ordinary message.
    @impl Viewport
    def handle_info({:show, screen}, state) do
      {:noreply, Renderer.rerender(%{state | screen: screen})}
    end

    def handle_info(_message, state), do: {:noreply, state}

    defp sink_pid(sink) when is_pid(sink), do: sink
    defp sink_pid(sink), do: Process.whereis(sink) || raise("No frame sink at #{inspect(sink)}")
  end
end
