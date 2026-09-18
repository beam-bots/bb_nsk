# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.BbNsk.PruneNifs do
  @shortdoc "Removes NIFs built for another architecture before a firmware build"
  @moduledoc """
  #{@shortdoc}

  `bb_nsk.add_display` puts this in front of `mix firmware`:

  ```elixir
  firmware: ["bb_nsk.prune_nifs", "firmware"]
  ```

  See `BB.NSK.MixHelpers` for why it is needed. Short version: every build
  shares one `deps/emerge/priv/native`, so a host `mix test` leaves an `x86_64`
  library where the firmware build can see it, and Nerves' release scrub rejects
  the whole image over it.

  Does nothing on the host.
  """

  use Mix.Task

  alias BB.NSK.MixHelpers

  @doc false
  @impl Mix.Task
  def run(_argv), do: MixHelpers.prune_host_nifs()
end
