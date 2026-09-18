# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.Display.Supervisor do
  @moduledoc """
  The panel, its renderer and the sink between them.

  `rest_for_one`, because each of these holds something belonging to the one
  before it: the sink draws through `EInk`, and the renderer is given the
  sink's *pid* — Emerge requires a live local process for a headless target and
  will not take a name. A sink that restarts would otherwise leave the renderer
  rendering into a dead process, which fails silently at the point where frames
  simply stop arriving.

  On the host `EInk` is absent, so frames are rendered and go nowhere, which is
  what makes a screen previewable without hardware.
  """

  use Supervisor

  alias BB.NSK.Display.{FrameSink, Viewport}

  # `eink` is a git dependency, so it cannot be a dependency of a Hex package at
  # all. `bb_nsk.add_display` puts it in the consumer's `mix.exs`; this module
  # only ever calls it, which needs no compile-time presence.
  @compile {:no_warn_undefined, EInk}

  @spec start_link(keyword) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    children =
      panel_children() ++
        [
          {FrameSink,
           name: FrameSink, mode: Keyword.get(opts, :mode, :bw1), draw: draw(), clear: clear()},
          {Viewport, name: Viewport, sink: FrameSink, mode: Keyword.get(opts, :mode, :bw1)}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  if Mix.target() == :host do
    defp panel_children, do: []
    defp draw, do: fn _frame, _refresh_type -> :ok end
    defp clear, do: fn -> :ok end
  else
    defp panel_children, do: [EInk]

    defp draw do
      fn frame, refresh_type ->
        EInk.draw(frame.data, palette: frame.palette, refresh_type: refresh_type)
      end
    end

    defp clear, do: fn -> EInk.clear(:white) end
  end
end
