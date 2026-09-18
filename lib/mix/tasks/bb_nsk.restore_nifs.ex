# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.BbNsk.RestoreNifs do
  @shortdoc "Puts the host's NIF back after a firmware build removed it"
  @moduledoc """
  #{@shortdoc}

  `bb_nsk.add_display` puts this in front of `mix test` and `mix run`:

  ```elixir
  test: ["bb_nsk.restore_nifs", "test"],
  run: ["bb_nsk.restore_nifs", "run"]
  ```

  It only does anything straight after a firmware build, which is the only time
  the host's library is missing. Restoring costs about two seconds and comes out
  of `rustler_precompiled`'s own cache rather than the network.

  See `BB.NSK.MixHelpers` for the whole story.
  """

  use Mix.Task

  alias BB.NSK.MixHelpers

  @doc false
  @impl Mix.Task
  def run(_argv), do: MixHelpers.restore_host_nifs()
end
