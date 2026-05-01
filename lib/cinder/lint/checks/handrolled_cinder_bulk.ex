defmodule Cinder.Lint.Checks.HandrolledCinderBulk do
  @moduledoc """
  Detects handrolled bulk-action loops over Cinder `selected_ids` that
  silently swallow errors, and (where structurally feasible) auto-fixes
  them by converting the handler to a `<:bulk_action>` slot.

  ## The shape this catches

      Enum.reduce(socket.assigns.selected_ids, 0, fn id, acc ->
        case Ash.get(MyApp.Resource, id) do
          {:ok, record} ->
            # ... do something ...
            acc + 1
          _ ->
            acc        # <-- the bug: error never reaches the user
        end
      end)

  Two failure modes hidden by this pattern:
  - the catch-all `_ ->` arm eats every authorization or not-found error
  - any `{:error, _}` from the inner update/destroy is ignored

  The correct pattern is Cinder's `<:bulk_action>` slot — see the
  "Bulk Actions" section of `usage-rules.md`. The slot drives
  `Ash.bulk_update`/`bulk_destroy`, authorizes correctly, logs every
  failure, and dispatches `on_success`/`on_error` to the parent.

  ## Auto-fix scope

  - **`Ash.destroy(record, ...)` body** → fully convertible. Inserts
    `<:bulk_action action={:destroy} ... on_success={:deleted} on_error={:delete_failed}>`
    in the `<Cinder.collection>` template, removes the
    `<button phx-click="delete_selected" ...>` (if any), deletes the
    `handle_event` clause, adds `handle_info` clauses for the success
    and error events.
  - **Other shapes (`Ash.update`, side-effecting code, etc.)** —
    detection only; auto-fix is a no-op. These need a per-resource
    idempotent action and possibly a function-form bulk_action; the
    fix is left to the developer to apply by hand or to a richer
    cross-file fix tool.

  Fix is idempotent: running the strategy on already-converted source
  produces the same source.

  ## Provenance
  - Author: Calvin (agent)
  - Source: cinder
  - Category: error_handling
  - Fixable: partial (destroy only, for now)
  """

  @behaviour MaestroTool.Lint.Check

  @impl true
  def meta do
    %{
      name: :handrolled_cinder_bulk,
      author: "Calvin",
      source: :cinder,
      category: :error_handling,
      severity: :error,
      fixable: true,
      description:
        "Detects Enum.reduce over selected_ids that silently swallows Ash.get/update failures. Use Cinder's <:bulk_action> slot."
    }
  end

  @impl true
  def check(ast, meta) do
    ast = ast || Sourceror.parse_string!(meta.source)

    {_, violations} =
      Macro.prewalk(ast, [], fn
        # Enum.reduce(_, _, fn ... end)
        {{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, m, [_coll, _init, fun]} = node, acc ->
          if reducer_swallows?(fun) do
            v = %{
              check: :handrolled_cinder_bulk,
              line: m[:line] || 1,
              severity: :error,
              message:
                "Handrolled bulk action over selected_ids swallows errors. Use Cinder's <:bulk_action> slot " <>
                  "(see cinder/usage-rules.md \"Bulk Actions\").",
              fixable: true,
              source_range: nil
            }

            {node, [v | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(violations)
  end

  @impl true
  def fix(source, violation) do
    with {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, handler} <- find_enclosing_handle_event(ast, violation.line),
         :destroy <- classify_handler_body(handler.body) do
      apply_destroy_fix(source, ast, handler)
    else
      _ -> source
    end
  end

  @doc false
  # The Lint.Check behaviour also defines fix/1 — older callers.
  @impl true
  def fix(source), do: source

  # --- Detection helpers ---

  defp reducer_swallows?({:fn, _, clauses}) when is_list(clauses) do
    Enum.any?(clauses, fn
      {:->, _, [_args, body]} -> body_has_silent_case?(body)
      _ -> false
    end)
  end

  defp reducer_swallows?(_), do: false

  defp body_has_silent_case?({:case, _, [_subject, [{{:__block__, _, [:do]}, clauses}]]}),
    do: silent_case?(clauses)

  defp body_has_silent_case?({:case, _, [_subject, [do: clauses]]}), do: silent_case?(clauses)

  defp body_has_silent_case?({:__block__, _, exprs}),
    do: Enum.any?(exprs, &body_has_silent_case?/1)

  defp body_has_silent_case?(_), do: false

  defp silent_case?(clauses) when is_list(clauses) do
    has_ok_arm?(clauses) and has_silent_default?(clauses)
  end

  defp silent_case?(_), do: false

  defp has_ok_arm?(clauses) do
    Enum.any?(clauses, fn
      {:->, _, [[pat], _body]} -> ok_tuple_pattern?(pat)
      _ -> false
    end)
  end

  defp ok_tuple_pattern?({:__block__, _, [{{:__block__, _, [:ok]}, _}]}), do: true
  defp ok_tuple_pattern?({:ok, _}), do: true
  defp ok_tuple_pattern?(_), do: false

  defp has_silent_default?(clauses) do
    Enum.any?(clauses, fn
      {:->, _, [[{:_, _, _}], body]} -> silent_body?(body)
      {:->, _, [[{:__block__, _, [{{:__block__, _, [:error]}, _}]}], body]} -> silent_body?(body)
      _ -> false
    end)
  end

  defp silent_body?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp silent_body?({:__block__, _, [val]}), do: silent_body?(val)
  defp silent_body?({a, b}), do: silent_body?(a) and silent_body?(b)
  defp silent_body?(atom) when is_atom(atom), do: true
  defp silent_body?(num) when is_number(num), do: true
  defp silent_body?(_), do: false

  # --- Find the enclosing handle_event def for a violation line ---

  defp find_enclosing_handle_event(ast, line) do
    handlers = collect_handle_events(ast)

    case Enum.find(handlers, fn h -> line >= h.start_line and line <= h.end_line end) do
      nil -> :error
      handler -> {:ok, handler}
    end
  end

  defp collect_handle_events(ast) do
    {_, handlers} =
      Macro.prewalk(ast, [], fn
        {:def, m, [{:handle_event, _, args}, [{{:__block__, _, [:do]}, body}]]} = node, acc ->
          handle(node, m, args, body, acc)

        {:def, m, [{:handle_event, _, args}, [do: body]]} = node, acc ->
          handle(node, m, args, body, acc)

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(handlers)
  end

  defp handle(node, m, [event, _, _], body, acc) do
    event_str = unwrap(event)

    if is_binary(event_str) and String.ends_with?(event_str, "_selected") do
      start_line = m[:line] || 1
      end_line = m[:end][:line] || start_line + 50

      {node, [%{event: event_str, start_line: start_line, end_line: end_line, body: body, node: node} | acc]}
    else
      {node, acc}
    end
  end

  defp handle(node, _, _, _, acc), do: {node, acc}

  defp unwrap({:__block__, _, [s]}) when is_binary(s), do: s
  defp unwrap(s) when is_binary(s), do: s
  defp unwrap(_), do: nil

  defp classify_handler_body(body) do
    cond do
      contains_call?(body, [:Ash], :destroy) -> :destroy
      contains_call?(body, [:Ash], :update) -> :update
      true -> :unknown
    end
  end

  defp contains_call?(ast, mod, fun) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, ^mod}, ^fun]}, _, _} = n, _ -> {n, true}
        n, acc -> {n, acc}
      end)

    found?
  end

  # --- The destroy fix ---

  defp apply_destroy_fix(source, ast, handler) do
    event = handler.event
    success = :deleted
    error = :delete_failed

    source
    |> remove_handle_event_def(handler.event, ast)
    |> add_handle_info_clauses(success, error)
    |> rewrite_render_template(event, fn tree ->
      tree
      |> Cinder.HEExTransforms.insert_bulk_action_slot(:destroy,
        label: "Delete ({count})",
        variant: :danger,
        confirm: "Delete {count}?",
        on_success: success,
        on_error: error
      )
      |> Cinder.HEExTransforms.remove_button_with_phx_click(event)
    end)
  end

  # Remove the `def handle_event("<event>_selected", ...) do ... end` clause via
  # zipper navigation. We re-parse to keep zipper positions clean.
  defp remove_handle_event_def(source, event, _ast) do
    {:ok, ast} = Sourceror.parse_string(source)

    new_ast =
      Macro.prewalk(ast, fn
        {:def, _m, [{:handle_event, _, args}, [{{:__block__, _, [:do]}, _body}]]} = node ->
          if matches_event?(args, event), do: :__remove__, else: node

        {:def, _m, [{:handle_event, _, args}, [do: _body]]} = node ->
          if matches_event?(args, event), do: :__remove__, else: node

        # Strip @impl true preceding a removed def — appears as a __block__ pair
        {:__block__, m, exprs} ->
          {:__block__, m, drop_impl_before_removed(exprs)}

        node ->
          node
      end)

    new_ast = strip_removed(new_ast)

    Sourceror.to_string(new_ast)
  end

  defp matches_event?([event_node, _, _], event) do
    case unwrap(event_node) do
      ^event -> true
      _ -> false
    end
  end

  defp matches_event?(_, _), do: false

  defp drop_impl_before_removed(exprs) do
    exprs
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.flat_map(fn
      [{:@, _, [{:impl, _, [{:__block__, _, [true]}]}]}, :__remove__] -> []
      [first, _] -> [first]
    end)
  end

  defp strip_removed(ast) do
    Macro.prewalk(ast, fn
      {:__block__, m, exprs} -> {:__block__, m, Enum.reject(exprs, &(&1 == :__remove__))}
      other -> other
    end)
  end

  # Append `def handle_info({:<success>, _}, socket)` and `def handle_info({:<error>, ...}, socket)`
  # clauses to the module. Idempotent — checks for existing clauses with the same atom.
  defp add_handle_info_clauses(source, success, error) do
    needs_success = not has_handle_info?(source, success)
    needs_error = not has_handle_info?(source, error)

    cond do
      not (needs_success or needs_error) ->
        source

      true ->
        new_clauses =
          [
            needs_success &&
              ~s"""

                @impl true
                def handle_info({:#{success}, %{count: count}}, socket) do
                  {:noreply, put_flash(socket, :info, "Deleted \#{count} record(s)")}
                end
              """,
            needs_error &&
              ~s"""

                def handle_info({:#{error}, %{reason: reason}}, socket) do
                  {:noreply, put_flash(socket, :error, "Delete failed: \#{inspect(reason)}")}
                end
              """
          ]
          |> Enum.filter(& &1)
          |> Enum.join("")

        # Insert before the last `end` in the module body
        Regex.replace(~r/(\nend\s*\n*)\z/, source, new_clauses <> "\n\\1")
    end
  end

  defp has_handle_info?(source, atom) do
    String.contains?(source, "def handle_info({:#{atom}")
  end

  # --- HEEx sigil rewrite ---

  # Find the `~H"""..."""` sigil in render/1, parse via HEExParser, transform
  # the tree with `transformer`, serialize back, and replace the sigil body
  # in the source. Preserves the leading indentation level of the original.
  defp rewrite_render_template(source, _event, transformer) do
    case Regex.run(~r/(~H""")(.*?)(""")/s, source, return: :index) do
      nil ->
        source

      [_full, _open, body_idx, _close] ->
        {body_start, body_len} = body_idx
        original_body = String.slice(source, body_start, body_len)

        # Detect indent: first non-empty line of original body
        indent = detect_body_indent(original_body)

        # HEExParser is happier without leading newline + indent; un-indent first
        unindented = strip_leading_indent(original_body, indent)

        new_body =
          case MaestroTool.HEExParser.parse(unindented) do
            {:ok, tree} ->
              tree
              |> transformer.()
              |> MaestroTool.HEExParser.to_heex()
              |> reindent(indent)

            {:error, _} ->
              original_body
          end

        if new_body == original_body do
          source
        else
          before = String.slice(source, 0, body_start)
          rest = String.slice(source, body_start + body_len, byte_size(source) - body_start - body_len)
          before <> new_body <> rest
        end
    end
  end

  # Find indent of first non-blank, non-leading-newline line.
  defp detect_body_indent(body) do
    body
    |> String.split("\n")
    |> Enum.find_value("", fn line ->
      trimmed = String.trim_leading(line, " ")

      cond do
        trimmed == "" -> nil
        true -> String.duplicate(" ", String.length(line) - String.length(trimmed))
      end
    end)
  end

  defp strip_leading_indent(body, ""), do: body

  defp strip_leading_indent(body, indent) do
    body
    |> String.split("\n")
    |> Enum.map(fn line ->
      if String.starts_with?(line, indent), do: String.slice(line, byte_size(indent), byte_size(line)), else: line
    end)
    |> Enum.join("\n")
  end

  defp reindent(body, indent) do
    trimmed = String.trim(body)

    indented =
      trimmed
      |> String.split("\n")
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> indent <> line
      end)

    "\n" <> indented <> "\n" <> indent
  end
end
