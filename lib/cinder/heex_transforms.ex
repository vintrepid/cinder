defmodule Cinder.HEExTransforms do
  @moduledoc """
  HEEx tree transforms used by `mix cinder.gen.collection` when
  refactoring handrolled bulk handlers into `<:bulk_action>` slots.

  All transforms operate on the `MaestroTool.HEExParser` AST shape.
  Round-trip safe: parse → transform → `to_heex/1`.
  """

  @type heex_tree :: list()

  @doc """
  Insert a `<:bulk_action>` slot into the first `<Cinder.collection>` block
  found in the tree. Idempotent — if a `<:bulk_action>` with the same
  `action` already exists in that block, the tree is returned unchanged.

  `attrs` is a keyword list whose keys map to slot attribute names; values
  shaped as `{:string, "literal", _}`, `{:expr, "ast as text", _}`, or `nil`
  (boolean attrs).
  """
  @spec insert_bulk_action_slot(heex_tree(), atom(), keyword()) :: heex_tree()
  def insert_bulk_action_slot(tree, action, attrs) when is_atom(action) do
    MaestroTool.HEExParser.traverse(tree, fn
      {:tag_block, "Cinder.collection", col_attrs, children, meta} ->
        if has_bulk_action?(children, action) do
          {:tag_block, "Cinder.collection", col_attrs, children, meta}
        else
          slot = build_bulk_action_node(action, attrs)
          new_children = prepend_with_padding(children, slot)
          {:tag_block, "Cinder.collection", col_attrs, new_children, meta}
        end

      node ->
        node
    end)
  end

  @doc """
  Remove every `<button phx-click="<event>" ...>...</button>` from the
  tree. Idempotent — removing nothing when nothing matches.
  """
  @spec remove_button_with_phx_click(heex_tree(), String.t()) :: heex_tree()
  def remove_button_with_phx_click(tree, event) when is_list(tree) do
    tree
    |> Enum.flat_map(&remove_button_walk(&1, event))
    |> drop_orphan_whitespace()
  end

  # Returns a list of nodes (so a removal yields []).
  defp remove_button_walk({:tag_block, "button", attrs, _children, _meta} = node, event) do
    if attr_equals?(attrs, "phx-click", event), do: [], else: [node]
  end

  defp remove_button_walk({:tag_block, name, attrs, children, meta}, event) do
    new_children =
      children
      |> Enum.flat_map(&remove_button_walk(&1, event))
      |> drop_orphan_whitespace()

    [{:tag_block, name, attrs, new_children, meta}]
  end

  defp remove_button_walk({:eex_block, expr, branches, meta}, event) do
    new_branches =
      Enum.map(branches, fn {children, closing} ->
        kids =
          children
          |> Enum.flat_map(&remove_button_walk(&1, event))
          |> drop_orphan_whitespace()

        {kids, closing}
      end)

    [{:eex_block, expr, new_branches, meta}]
  end

  defp remove_button_walk(node, _event), do: [node]

  # --- Internals ---

  defp has_bulk_action?(children, action) do
    Enum.any?(children, fn
      {:tag_self_close, ":bulk_action", attrs} ->
        attr_equals_expr?(attrs, "action", ":#{action}")

      {:tag_block, ":bulk_action", attrs, _, _} ->
        attr_equals_expr?(attrs, "action", ":#{action}")

      _ ->
        false
    end)
  end

  defp build_bulk_action_node(action, attrs) do
    base_attrs =
      [
        {"action", {:expr, ":#{action}", %{}}, %{}}
      ]

    extra_attrs =
      Enum.map(attrs, fn
        {key, {:string, _, _} = v} -> {to_string(key), v, %{}}
        {key, {:expr, _, _} = v} -> {to_string(key), v, %{}}
        {key, value} when is_binary(value) -> {to_string(key), {:string, value, %{delimiter: 34}}, %{}}
        {key, value} when is_atom(value) -> {to_string(key), {:expr, ":#{value}", %{}}, %{}}
      end)

    {:tag_self_close, ":bulk_action", base_attrs ++ extra_attrs}
  end

  defp prepend_with_padding([{:text, _, _} = leading_pad | rest], node) do
    [leading_pad, node, leading_pad | rest]
  end

  defp prepend_with_padding(children, node) do
    [{:text, "\n  ", %{newlines: 1}}, node | children]
  end

  defp attr_equals?(attrs, key, expected) do
    Enum.any?(attrs, fn
      {^key, {:string, ^expected, _}, _} -> true
      _ -> false
    end)
  end

  defp attr_equals_expr?(attrs, key, expected_expr) do
    Enum.any?(attrs, fn
      {^key, {:expr, ^expected_expr, _}, _} -> true
      _ -> false
    end)
  end

  defp drop_orphan_whitespace(children) do
    # Collapse runs of whitespace-only text nodes that may be left after a
    # removal, so we don't leave doubled blank lines.
    children
    |> Enum.chunk_by(&whitespace?/1)
    |> Enum.flat_map(fn
      [first | _] = chunk ->
        if whitespace?(first), do: [first], else: chunk
    end)
  end

  defp whitespace?({:text, text, _}), do: String.trim(text) == ""
  defp whitespace?(_), do: false
end
