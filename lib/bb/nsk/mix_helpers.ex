# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.NSK.MixHelpers do
  @moduledoc """
  Aliases a project needs when it draws on the panel.

  `bb_nsk.add_display` wires these into `mix.exs` as ordinary Mix tasks:

  ```elixir
  firmware: ["bb_nsk.prune_nifs", "firmware"],
  test: ["bb_nsk.restore_nifs", "test"],
  run: ["bb_nsk.restore_nifs", "run"]
  ```

  Tasks rather than function references. An alias entry is either a task name or
  a function, and Igniter writes a function reference into `mix.exs` as a literal
  `{:code, ...}` tuple that Mix then rejects — but a task name is just a string,
  which needs nothing special from anybody.

  ## Why they are needed

  `rustler_precompiled` keeps every NIF it has ever downloaded in
  `deps/emerge/priv/native`, and Mix symlinks *every* build's `emerge/priv` at
  that one directory — `_build/dev`, `_build/test` and `_build/trellis_dev`
  alike. So the host's library and the board's share a directory, and each one's
  build breaks the other's:

  - a host `mix test` leaves an `x86_64` library where the firmware build can
    see it, and Nerves' release scrub rejects the whole image, naming the file
    rather than the cause;
  - pruning it so the firmware builds then leaves the host with no library to
    load, and Emerge's `on_load` fails.

  So the two are handled as a pair rather than one being fixed at the other's
  expense. Restoring costs about two seconds and comes out of
  `rustler_precompiled`'s own cache rather than the network, and it only runs
  when the library is actually missing — which is only ever straight after a
  firmware build.

  This lives in the library rather than being generated into `mix.exs` so that
  the workaround improves for everyone when it is improved at all.
  """

  @target_arch "armv7"

  @doc """
  Remove any NIF that isn't this board's, so a firmware build passes the scrub.

  Does nothing on the host, where the foreign library is the one that is wanted.
  """
  @spec prune_host_nifs() :: :ok
  def prune_host_nifs do
    if Mix.target() != :host do
      Enum.each(nifs(matching?: false), fn nif ->
        Mix.shell().info("Removing #{Path.basename(nif)}, which is not #{@target_arch}")
        File.rm!(nif)
      end)
    end

    :ok
  end

  @doc """
  Put the host's NIF back, if a firmware build took it away.
  """
  @spec restore_host_nifs() :: :ok
  def restore_host_nifs do
    if Mix.target() == :host and nifs(matching?: false) == [] do
      Mix.shell().info("Restoring the host's Emerge NIF, which a firmware build removed")
      Mix.Task.run("deps.compile", ["emerge", "--force"])
    end

    :ok
  end

  defp nifs(matching?: matching?) do
    "deps/emerge/priv/native/*.so"
    |> Path.wildcard()
    |> Enum.filter(&(String.contains?(Path.basename(&1), @target_arch) == matching?))
  end
end
