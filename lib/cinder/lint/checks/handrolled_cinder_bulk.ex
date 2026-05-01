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
         {:ok, handler} <- find_enclosing_handle_event(ast, violation.line) do
      case classify_handler_body(handler.body) do
        :destroy -> apply_destroy_fix(source, ast, handler)
        :update -> apply_update_fix(source, ast, handler)
        _ -> source
      end
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
      # `Ash.update(...)` OR a code-interface call like `MyResource.update(...)`
      contains_any_call?(body, :update) -> :update
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

  # Any module-qualified call to `fun`, regardless of which module.
  defp contains_any_call?(ast, fun) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, _}, ^fun]}, _, _} = n, _ -> {n, true}
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
    |> add_handle_info_clauses(success, error, "Deleted")
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

  # --- The update fix (cross-file: needs an idempotent action on the resource) ---

  defp apply_update_fix(source, _ast, handler) do
    with {:ok, raw_mod} <- extract_resource_module(handler.body),
         resource_mod = resolve_alias_in_source(raw_mod, source),
         {:ok, param_map} <- extract_param_map(handler.body, resource_mod),
         action_atom <- action_atom_from_event(handler.event),
         success = success_atom(action_atom),
         error = error_atom(action_atom),
         {:ok, _} <- ensure_idempotent_action_on_resource(resource_mod, action_atom, param_map) do
      action_label = humanize(action_atom)

      source
      |> remove_handle_event_def(handler.event, nil)
      |> add_handle_info_clauses(success, error, action_label_past(action_label))
      |> rewrite_render_template(handler.event, fn tree ->
        tree
        |> Cinder.HEExTransforms.insert_bulk_action_slot(action_atom,
          label: "#{action_label} ({count})",
          confirm: "#{action_label} {count}?",
          on_success: success,
          on_error: error
        )
        |> Cinder.HEExTransforms.remove_button_with_phx_click(handler.event)
      end)
    else
      _ -> source
    end
  end

  # Find Ash.get(<aliases>, _) in the handler body to learn the resource
  defp extract_resource_module(body) do
    {_, found} =
      Macro.prewalk(body, nil, fn
        {{:., _, [{:__aliases__, _, [:Ash]}, :get]}, _, [resource_ast | _]} = node, nil ->
          {node, alias_to_module(resource_ast)}

        node, acc ->
          {node, acc}
      end)

    case found do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  # Param map shapes:
  #   Ash.Changeset.for_update(:action_atom, %{key: val, ...})
  #   <Resource>.update(record, %{key: val, ...})
  defp extract_param_map(body, _resource) do
    {_, found} =
      Macro.prewalk(body, nil, fn
        # Ash.Changeset.for_update(action, params)
        {{:., _, [{:__aliases__, _, [:Ash, :Changeset]}, :for_update]}, _, [_action, params_ast | _]} = node,
        nil ->
          {node, decode_map(params_ast)}

        # <Module>.update(record, params)
        {{:., _, [{:__aliases__, _, _}, :update]}, _, [_record, params_ast | _]} = node, nil ->
          {node, decode_map(params_ast)}

        node, acc ->
          {node, acc}
      end)

    case found do
      nil -> :error
      [] -> :error
      kw -> {:ok, kw}
    end
  end

  # Decode `%{a: 1, b: :x}` AST into a keyword list of {atom, ast_value}.
  defp decode_map({:%{}, _, pairs}) do
    Enum.map(pairs, fn
      {{:__block__, _, [k]}, v} when is_atom(k) -> {k, unwrap_value(v)}
      {k, v} when is_atom(k) -> {k, unwrap_value(v)}
    end)
  end

  defp decode_map({:__block__, _, [{:%{}, _, _} = m]}), do: decode_map(m)
  defp decode_map(_), do: nil

  defp unwrap_value({:__block__, _, [v]}), do: v
  defp unwrap_value(v), do: v

  defp alias_to_module({:__aliases__, _, segments}) when is_list(segments) do
    Module.concat(segments)
  end

  defp alias_to_module(_), do: nil

  # If the bare module isn't loadable, scan the source for `alias X.Y.Z` and
  # match by the last segment. Returns the resolved module (or the input
  # unchanged when nothing matches).
  defp resolve_alias_in_source(mod, source) do
    if Code.ensure_loaded?(mod) do
      mod
    else
      short = mod |> Module.split() |> List.last()

      aliases =
        Regex.scan(~r/alias\s+([\w.]+(?:\.\{[^}]+\})?)/, source)
        |> Enum.flat_map(fn [_, expr] -> expand_alias_expr(expr) end)

      case Enum.find(aliases, fn full -> List.last(String.split(full, ".")) == short end) do
        nil -> mod
        full -> Module.concat(String.split(full, "."))
      end
    end
  end

  # Expand `Foo.Bar.{A, B}` shorthand into ["Foo.Bar.A", "Foo.Bar.B"].
  defp expand_alias_expr(expr) do
    case Regex.run(~r/^([\w.]+)\.\{([^}]+)\}$/, expr) do
      [_, prefix, inner] ->
        inner
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(fn name -> prefix <> "." <> name end)

      nil ->
        [expr]
    end
  end

  # If the action already exists on the resource, treat as already-fixed.
  # Otherwise splice an idempotent update action and write the resource file.
  defp ensure_idempotent_action_on_resource(resource_mod, action_atom, param_kw) do
    if Code.ensure_loaded?(resource_mod) and action_exists?(resource_mod, action_atom) do
      {:ok, :already_present}
    else
      splice_action_into_resource_file(resource_mod, action_atom, param_kw)
    end
  end

  defp action_exists?(resource_mod, action_atom) do
    Enum.any?(Ash.Resource.Info.actions(resource_mod), &(&1.name == action_atom))
  end

  defp splice_action_into_resource_file(resource_mod, action_atom, param_kw) do
    case resource_source_path(resource_mod) do
      nil ->
        :error

      path ->
        source = File.read!(path)
        new_source = insert_action_block(source, action_atom, param_kw)

        if new_source == source do
          {:ok, :no_change}
        else
          File.write!(path, new_source)
          {:ok, :spliced}
        end
    end
  end

  defp resource_source_path(resource_mod) do
    case resource_mod.module_info(:compile)[:source] do
      nil -> nil
      src -> to_string(src)
    end
  end

  # Insert `update :name do ... end` just before `end` of the `actions do`
  # block. String-level operation guarded by AST awareness — finds the
  # `actions do` opening via Sourceror, locates its end line, splices.
  defp insert_action_block(source, action_atom, param_kw) do
    case Sourceror.parse_string(source) do
      {:error, _} ->
        source

      {:ok, ast} ->
        case find_actions_block_end_line(ast) do
          nil -> source
          end_line -> splice_at_end_line(source, end_line, render_action(action_atom, param_kw))
        end
    end
  end

  defp find_actions_block_end_line(ast) do
    {_, line} =
      Macro.prewalk(ast, nil, fn
        {:actions, m, [[do: _]]} = node, nil ->
          {node, m[:end][:line]}

        {:actions, m, [[{{:__block__, _, [:do]}, _}]]} = node, nil ->
          {node, m[:end][:line]}

        node, acc ->
          {node, acc}
      end)

    line
  end

  defp splice_at_end_line(source, end_line, block) do
    lines = String.split(source, "\n")

    {before_lines, end_and_after} = Enum.split(lines, end_line - 1)

    indent = "    "
    indented_block = String.split(block, "\n") |> Enum.map_join("\n", &(indent <> &1))

    (before_lines ++ [indented_block] ++ end_and_after)
    |> Enum.join("\n")
  end

  defp render_action(action_atom, param_kw) do
    changes =
      param_kw
      |> Enum.map_join("\n      ",
        fn {k, v} -> "change set_attribute(:#{k}, #{Macro.to_string(v)})" end)

    """
    update :#{action_atom} do
      description "Auto-generated by Cinder.Lint.Checks.HandrolledCinderBulk fix/2."
      accept []
      require_atomic? true
      #{changes}
    end
    """
  end

  defp humanize(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp action_label_past("Delete"), do: "Deleted"
  defp action_label_past(label), do: label <> "d"

  defp action_atom_from_event(event_str) do
    event_str
    |> String.trim_trailing("_selected")
    |> String.to_atom()
  end

  defp success_atom(:destroy), do: :deleted
  defp success_atom(action), do: String.to_atom(Atom.to_string(action) <> "d")

  defp error_atom(:destroy), do: :delete_failed
  defp error_atom(action), do: String.to_atom(Atom.to_string(action) <> "_failed")

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
  defp add_handle_info_clauses(source, success, error, success_label) do
    needs_success = not has_handle_info?(source, success)
    needs_error = not has_handle_info?(source, error)

    error_label = String.replace(success_label, ~r/d$/, "") <> " failed"

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
                  {:noreply, put_flash(socket, :info, "#{success_label} \#{count} record(s)")}
                end
              """,
            needs_error &&
              ~s"""

                def handle_info({:#{error}, %{reason: reason}}, socket) do
                  {:noreply, put_flash(socket, :error, "#{error_label}: \#{inspect(reason)}")}
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
