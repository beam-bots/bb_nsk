# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

# The panel's rendering stack needs `emerge`, which is an optional dependency —
# a robot that only balances has no business pulling a Skia NIF into its
# firmware. `bb_nsk.add_display` adds it, and then these compile.
if Code.ensure_loaded?(Emerge.UI) do
  defmodule BB.NSK.Display.TestCard do
    @moduledoc """
    A screen exercising text and each of the basic shapes, for checking that the
    panel is wired up and that the rendering pipeline is the right way up.

    Show it on the device, naming your robot:

        iex> BB.NSK.Display.TestCard.show(MyBot.Robot)

    `screen/0` is pure, so the layout can be worked on from the host without
    hardware — see the previewing section of `CLAUDE.md`.
    """

    use Emerge.UI

    alias BB.NSK.Display

    @spec screen() :: Emerge.tree()
    def screen do
      column(
        [
          width(fill()),
          height(fill()),
          Background.color(white()),
          Font.color(black()),
          Border.width(2),
          Border.color(black()),
          padding(16),
          spacing(14)
        ],
        [
          row([width(fill()), spacing(20)], [
            el([width(px(90)), height(px(65)), Background.color(black())], none()),
            el(
              [
                width(px(66)),
                height(px(66)),
                Border.rounded(33),
                Border.width(2),
                Border.color(black())
              ],
              none()
            ),
            el(
              [width(px(66)), height(px(66)), Border.rounded(33), Background.color(black())],
              none()
            )
          ]),
          el([Font.family("Spleen"), Font.size(24)], text("emerge + eink")),
          el([Font.family("Spleen"), Font.size(24)], text("400x300 1bpp")),
          el([width(fill()), height(px(2)), Background.color(black())], none()),
          el([Font.family("Spleen Title"), Font.size(48)], text(Display.name())),
          el([width(fill()), height(fill())], none())
        ]
      )
    end

    @spec show(module, keyword) :: :ok | {:error, term}
    def show(robot, opts \\ []) do
      Display.Controller.render(robot, screen(), opts)
    end

    defp black, do: color_rgb(0, 0, 0)
    defp white, do: color_rgb(255, 255, 255)
  end
end
