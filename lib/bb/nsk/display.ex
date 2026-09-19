# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

# The panel's rendering stack needs `emerge`, which is an optional dependency —
# a robot that only balances has no business pulling a Skia NIF into its
# firmware. `bb_nsk.add_display` adds it, and then these compile.
if Code.ensure_loaded?(Emerge.UI) do
  defmodule BB.NSK.Display do
    @moduledoc """
    The board's 4.2" e-paper panel: its size, its fonts and its packed formats.

    The panel is owned by `BB.NSK.Display.FrameSink` and drawn by
    `BB.NSK.Display.Viewport`. Everything here is pure, so screens can be built
    and inspected from the host without hardware.

    Nothing here rasterises. Emerge renders a screen with Skia and packs it to one
    or two bits per pixel on the Rust side, so the Elixir side never handles a
    pixel. That matters more than it sounds: the panel is 120,000 pixels and
    15,000 bytes, and anything that walks that in Elixir costs about as long as
    the panel takes to show it.
    """

    alias Emerge.UI

    # Spleen's outline release rather than its bitmap one, because Skia takes
    # `.ttf`, `.otf` and `.ttc` and not `.bdf`. The outline build draws each pixel
    # of the original as a square, so at the sizes the screens use it still lands
    # one pixel per pixel. Two families rather than one scaled, for the same
    # reason the bitmap build shipped two sizes.
    @fonts [
      [family: "Spleen", source: "fonts/spleen-8x16.otf", weight: 400],
      [family: "Spleen Title", source: "fonts/spleen-16x32.otf", weight: 400]
    ]

    # Three levels up, not two: this module sits at `lib/bb/nsk/`, a directory
    # deeper than it did in the prototype. Pointing these at a path that does not
    # exist costs nothing visible — they only exist so that editing a font forces
    # a recompile — which is exactly why it is worth getting right rather than
    # discovering later that it never worked.
    @fonts_dir Path.join([__DIR__, "..", "..", "..", "priv", "fonts"])

    @external_resource Path.join(@fonts_dir, "spleen-8x16.otf")
    @external_resource Path.join(@fonts_dir, "spleen-16x32.otf")

    @width 400
    @height 300

    # `stride` and `bytes` are what a frame off the renderer has to measure to be
    # believed, and they are derived rather than written down: `bw1` packs eight
    # pixels to a byte and `gray2` four, and 400 pixels divides evenly by both.
    #
    # `one_is_white` matches the panel's own sense of a set bit, and `dither`
    # buys Atkinson error diffusion over photographs while leaving text, borders
    # and vector edges crisp — Emerge protects those from diffusion itself.
    @modes %{
      bw1: %{
        pixel_format: :bw1,
        palette: :bw,
        bw1_polarity: :one_is_white,
        dither: true,
        pixels_per_byte: 8
      },
      gray2: %{
        pixel_format: :gray2,
        palette: :gray2,
        bw1_polarity: :one_is_white,
        dither: true,
        pixels_per_byte: 4
      }
    }

    @doc """
    The panel's size in pixels, as `{width, height}`.
    """
    @spec size() :: {pos_integer, pos_integer}
    def size, do: {@width, @height}

    @doc """
    The fonts the panel's screens are drawn with, as an Emerge asset config.

    Registered once against the renderer when the viewport mounts, and asked for
    by family in a screen. Handing them to a render call instead re-reads and
    re-parses both files every time, which costs ninety times what drawing the
    whole dashboard does.
    """
    @spec fonts() :: [keyword]
    def fonts, do: @fonts

    @doc """
    The robot's name, as a screen shows it.

    `BB.NSK.name/0` rather than written down, so that a robot built from this
    wears its own name without anybody remembering to edit a screen. The
    dashboard's heading and the test card both ask for it, and before this they
    were two literals free to disagree.
    """
    @spec name() :: String.t()
    def name, do: BB.NSK.name() |> String.upcase()

    @doc """
    The modes the panel can be driven in.

    `:bw1` is one bit per pixel and is what the panel has always been sent.
    `:gray2` is two bits per pixel and four levels, for twice the bytes.
    """
    @spec modes() :: [:bw1 | :gray2]
    def modes, do: Map.keys(@modes)

    @doc """
    The renderer and driver settings for a mode, and the frame geometry to expect
    back from it.
    """
    @spec mode(:bw1 | :gray2) :: map
    def mode(mode) when is_map_key(@modes, mode) do
      %{pixels_per_byte: pixels_per_byte} = profile = Map.fetch!(@modes, mode)
      stride = div(@width, pixels_per_byte)

      profile
      |> Map.put(:stride_bytes, stride)
      |> Map.put(:frame_bytes, stride * @height)
    end

    @doc """
    Wrap a screen in the panel's paper and orientation.

    Two things happen at this edge so that no screen has to know about either.

    Skia starts a surface transparent, which quantises to black, so a screen that
    painted no background of its own would cost a full black refresh on a panel
    that takes three seconds to change its mind. The paper is painted here.

    The panel is mounted upside down on the robot, so `upside_down` turns the
    whole screen half a turn. Skia does it as part of the paint, so it costs
    nothing and nothing upstream has to know — screens stay in the orientation a
    person reading the panel sees.
    """
    @spec paper(Emerge.tree(), boolean) :: Emerge.tree()
    def paper(tree, upside_down) do
      UI.el(
        [
          UI.Size.width(UI.Size.fill()),
          UI.Size.height(UI.Size.fill()),
          UI.Background.color(UI.Color.color_rgb(255, 255, 255))
        ] ++ orientation(upside_down),
        tree
      )
    end

    # A paint-only rotation, so the element keeps the layout slot it would have
    # had. At exactly half a turn on a whole number of pixels there is nothing to
    # resample, so this costs no sharpness.
    defp orientation(true), do: [UI.Transform.rotate(180)]
    defp orientation(false), do: []
  end
end
