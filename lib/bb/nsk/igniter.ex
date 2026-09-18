# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule BB.NSK.Igniter do
    @moduledoc """
    Helpers the `bb_nsk.add_*` tasks share.

    `BB.Igniter` covers most of what an installer needs, but its
    `populate_link/4` deliberately refuses a link that already has a body — it
    exists to fill an empty `link :base_link do end` without trampling a user's
    edits — and it walks down to a link through a chain of enclosing links.

    Neither fits here. The Balance Bot's links are separated by joints rather
    than nested directly, and each task adds to a link that a previous task has
    already populated: `bb_nsk.install` gives `:base_link` its visual and
    inertial, and the wheels and the IMU mount hang off it afterwards.

    So these search the topology for a link by name and append to it. Names are
    unique across a BB topology, which is what makes the search unambiguous.

    Only available when `:igniter` is loaded.
    """

    alias Igniter.Code.Common
    alias Sourceror.Zipper

    @doc """
    Append `code` to the body of the link named `link`, wherever it sits in the
    topology.
    """
    @spec append_to_link(Igniter.t(), module(), atom(), String.t(), {atom(), atom()}) ::
            Igniter.t()
    def append_to_link(igniter, robot_module, link, code, marker) do
      append_to(igniter, robot_module, {:link, link}, code, marker)
    end

    @doc """
    Append `code` to the body of the joint named `joint`.

    Sensors that report a joint's own configuration belong in its body rather
    than on a link — the lean angle and the heading are both measurements *of a
    joint*, derived from an IMU hanging off a link somewhere below it.
    """
    @spec append_to_joint(Igniter.t(), module(), atom(), String.t(), {atom(), atom()}) ::
            Igniter.t()
    def append_to_joint(igniter, robot_module, joint, code, marker) do
      append_to(igniter, robot_module, {:joint, joint}, code, marker)
    end

    @doc """
    Append `code` to the body of a named topology entity.

    Idempotent through `marker`, an `{entity, name}` pair naming something the
    code adds — `{:joint, :left_wheel_joint}`, say. If that entity is already
    somewhere underneath, the igniter is returned unchanged, so a task can be run
    twice and a user's edits to what it added the first time survive.

    Returns the igniter unchanged if the target isn't there. Tasks check that for
    themselves with `entity_in_topology?/4` so they can say something useful
    about it.
    """
    @spec append_to(Igniter.t(), module(), {atom(), atom()}, String.t(), {atom(), atom()}) ::
            Igniter.t()
    def append_to(igniter, robot_module, {entity, name}, code, {marker_entity, marker_name}) do
      update_topology(igniter, robot_module, fn zipper ->
        with {:ok, body} <- entity_body(zipper, entity, name),
             false <- entity_present?(body, marker_entity, marker_name) do
          {:ok, Common.add_code(body, code)}
        else
          _already_there_or_missing -> {:ok, zipper}
        end
      end)
    end

    @doc """
    Whether the robot's topology has a link of this name.

    Tasks use it to check their preconditions, so that `bb_nsk.add_balance` run
    against a robot with no IMU says so rather than producing one that never
    stands up.
    """
    @spec link_exists?(Igniter.t(), module(), atom()) :: {Igniter.t(), boolean()}
    def link_exists?(igniter, robot_module, link) do
      entity_in_topology?(igniter, robot_module, :link, link)
    end

    @doc """
    Whether the robot's topology already carries an entity of this name — a
    link, a joint, a sensor or an actuator.

    Read-only, so it doesn't queue a change the way `Spark.Igniter.update_dsl`
    would.
    """
    @spec entity_in_topology?(Igniter.t(), module(), atom(), atom()) ::
            {Igniter.t(), boolean()}
    def entity_in_topology?(igniter, robot_module, entity, name) do
      case Igniter.Project.Module.find_module(igniter, robot_module) do
        {:ok, {igniter, _source, zipper}} ->
          {igniter, entity_present?(zipper, entity, name)}

        {:error, igniter} ->
          {igniter, false}
      end
    end

    defp update_topology(igniter, robot_module, fun) do
      Spark.Igniter.update_dsl(igniter, robot_module, [{:section, :topology}], nil, fun)
    end

    defp entity_body(zipper, entity, name) do
      case find_entity(zipper, entity, name) do
        {:ok, found} -> Common.move_to_do_block(found)
        :error -> :error
      end
    end

    # Searches the whole subtree rather than the current scope. A topology
    # alternates links and joints, so `:base_link` is two `do` blocks below
    # `:world` with a joint in each — nothing a scope-local search would reach.
    defp find_entity(zipper, entity, name) do
      case Zipper.find(zipper, &matches?(&1, entity, name)) do
        nil -> :error
        found -> {:ok, found}
      end
    end

    defp entity_present?(zipper, entity, name) do
      match?({:ok, _}, find_entity(zipper, entity, name))
    end

    # A name is an atom literal, which Sourceror may or may not have wrapped in
    # a `:__block__` depending on how the source was parsed.
    defp matches?({entity, _meta, [{:__block__, _, [name]} | _]}, entity, name), do: true
    defp matches?({entity, _meta, [name | _]}, entity, name) when is_atom(name), do: true
    defp matches?(_node, _entity, _name), do: false
  end
end
