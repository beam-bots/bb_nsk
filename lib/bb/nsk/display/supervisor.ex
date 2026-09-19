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

  require Logger

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
    Supervisor.init(children(opts), strategy: :rest_for_one)
  end

  # The renderer and the sink only exist when `emerge` was there to compile them
  # against — see their `Code.ensure_loaded?` guards. Handing a supervisor a
  # module that does not exist raises, which would take the whole application
  # down and leave a robot nobody can reach, so a missing renderer is reported
  # and skipped instead.
  defp children(opts) do
    if renderer_available?() do
      mode = Keyword.get(opts, :mode, :bw1)

      panel_children() ++
        [
          {FrameSink, name: FrameSink, mode: mode, draw: draw(), clear: clear()},
          {Viewport, name: Viewport, sink: FrameSink, mode: mode}
        ]
    else
      Logger.warning(
        "#{inspect(FrameSink)} and #{inspect(Viewport)} were not compiled, so the panel " <>
          "will stay blank. They need `emerge`, which `mix bb_nsk.add_display` adds — if it " <>
          "is in `mix.exs` already then it compiled after this package, and " <>
          "`mix deps.compile bb_nsk --force` will sort it out."
      )

      []
    end
  end

  defp renderer_available?,
    do: Code.ensure_loaded?(FrameSink) and Code.ensure_loaded?(Viewport)

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
