# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

# The panel's rendering stack needs `emerge`, which is an optional dependency —
# a robot that only balances has no business pulling a Skia NIF into its
# firmware. `bb_nsk.add_display` adds it, and then these compile.
if Code.ensure_loaded?(Emerge.UI) do
  defmodule BB.NSK.Display.Dashboard do
    @moduledoc """
    The panel's main screen: network, robot and system status.

    Pure — takes a `BB.NSK.Status` and returns an `Emerge` tree, so layouts can
    be built and checked from the host without hardware.

    The panel is 400x300 and drawn with Spleen at its native 8x16, which works out
    at fifty characters across a full-width line. Where the layout used to be
    arithmetic over measured text, it is now a tree: a `row` puts a label beside a
    value, a filling spacer pushes a decoration to the right margin, and the
    column divides what is left over between the groups.
    """

    use Emerge.UI

    alias BB.NSK.Display
    alias BB.NSK.Status

    @body 16
    @title 32

    @margin 12
    @row_gap 3
    @rule_gap 7

    # The panel is drawn with a monospaced face, so the label column is a count of
    # characters rather than something to be measured: the widest label is five
    # characters, and a value starts two after it.
    @label_columns 7
    @column_width 8

    @meter_segments 5
    @segment_width 9
    @segment_gap 4
    @segment_height 12

    # No line on the panel can show much over thirty characters, so a value longer
    # than this has nothing more to tell the reader.
    @max_graphemes 64

    @connection_labels %{internet: "internet", lan: "lan", disconnected: "offline"}

    @spec screen(Status.t()) :: Emerge.tree()
    def screen(%Status{} = status) do
      column(
        [
          width(fill()),
          height(fill()),
          Font.family("Spleen"),
          Font.size(@body),
          Font.color(black()),
          Border.width(2),
          Border.color(black()),
          padding(@margin),
          spacing(@row_gap)
        ],
        [
          heading(status),
          rule(),
          field("ip", status.ip, connection(status)),
          field("wifi", status.ssid, meter(status.signal_percent))
        ] ++
          passphrase(status) ++
          [
            rule(),
            field("state", state(status)),
            field("up", uptime(status.uptime_ms)),
            field("fw", firmware(status)),
            field(
              "mem",
              percent(status.memory_percent),
              value("load #{load(status.load_average)}")
            ),
            field(
              "temp",
              temperature(status.temperature_c),
              value("rh #{percent(status.humidity_percent)}")
            ),
            field("batt", percent(status.battery_percent)),
            field("host", hostname(status.hostname)),
            spacer()
          ]
      )
    end

    # Only while the robot is its own network, where it is the one thing a person
    # standing in front of it actually needs and cannot get anywhere else. A robot
    # that has joined a network shows nothing here, so the passphrase isn't left
    # sitting on a screen in a room.
    defp passphrase(%Status{access_point_passphrase: nil}), do: []

    defp passphrase(%Status{access_point_passphrase: passphrase}),
      do: [field("key", passphrase)]

    defp heading(status) do
      row([width(fill()), Font.family("Spleen Title"), Font.size(@title)], [
        value(Display.name()),
        spacer(),
        value(status.safety_state |> text_or_unknown() |> String.upcase())
      ])
    end

    # The value takes whatever the label and the decoration leave, which is what
    # keeps a long SSID off the signal meter: Emerge clips a child to its box, so
    # the value is cut at exactly the point the meter begins. That is a harder
    # edge than the ellipsis the measured layout used to produce, and it is the
    # one thing this screen lost in the move — Emerge has no eliding text.
    defp field(label, content, decoration \\ none()) do
      row([width(fill()), height(px(@body))], [
        el([width(px(@label_columns * @column_width))], text(label)),
        el([width(fill())], text(text_or_unknown(content))),
        decoration
      ])
    end

    defp connection(%Status{connection: connection}) do
      value(Map.get(@connection_labels, connection, unknown()))
    end

    defp meter(nil), do: none()

    defp meter(percent) do
      filled = round(percent / 100 * @meter_segments)

      row(
        [spacing(@segment_gap), center_y()],
        Enum.map(0..(@meter_segments - 1), &segment(&1 < filled))
      )
    end

    defp segment(filled?) do
      el(
        [
          width(px(@segment_width)),
          height(px(@segment_height)),
          Border.width(2),
          Border.color(black()),
          Background.color(if(filled?, do: black(), else: white()))
        ],
        none()
      )
    end

    defp rule do
      el(
        [width(fill()), padding_xy(0, @rule_gap)],
        el([width(fill()), height(px(2)), Background.color(black())], none())
      )
    end

    # A `fill` with nothing in it: between two things it pushes them apart, and at
    # the end of the column it takes up whatever the rows left over.
    defp spacer, do: el([width(fill()), height(fill())], none())

    defp value(string), do: el([], text(String.slice(string, 0, @max_graphemes)))

    defp black, do: color_rgb(0, 0, 0)
    defp white, do: color_rgb(255, 255, 255)

    defp state(%Status{safety_state: safety, operational_state: nil}),
      do: text_or_unknown(safety)

    defp state(%Status{safety_state: safety, operational_state: operational}),
      do: "#{safety} / #{operational}"

    defp firmware(%Status{firmware_version: nil}), do: unknown()

    defp firmware(%Status{firmware_version: version, firmware_valid?: true}),
      do: "#{version} valid"

    defp firmware(%Status{firmware_version: version, firmware_valid?: false}),
      do: "#{version} INVALID"

    defp firmware(%Status{firmware_version: version}), do: version

    defp uptime(nil), do: unknown()

    defp uptime(milliseconds) do
      {days, {hours, minutes, _seconds}} =
        :calendar.seconds_to_daystime(div(milliseconds, 1_000))

      padded = "#{pad(hours)}:#{pad(minutes)}"

      case days do
        0 -> padded
        days -> "#{days}d #{padded}"
      end
    end

    defp hostname(nil), do: unknown()
    defp hostname(hostname), do: "#{hostname}.local"

    defp load(nil), do: unknown()
    defp load(load), do: :erlang.float_to_binary(load, decimals: 2)

    defp percent(nil), do: unknown()
    defp percent(percent) when is_float(percent), do: "#{round(percent)}%"
    defp percent(percent), do: "#{percent}%"

    defp temperature(nil), do: unknown()
    defp temperature(celsius), do: "#{:erlang.float_to_binary(celsius, decimals: 1)}C"

    defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

    defp text_or_unknown(nil), do: unknown()

    defp text_or_unknown(value) do
      case String.trim(to_string(value)) do
        "" -> unknown()
        trimmed -> trimmed
      end
    end

    defp unknown, do: "n/a"
  end
end
