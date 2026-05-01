if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Cinder.Gen.Collection do
    @example """
    mix cinder.gen.collection MyAppWeb.UsersLive MyApp.Accounts.User
    mix cinder.gen.collection MyAppWeb.UsersLive MyApp.Accounts.User --bulk-actions approve,destroy
    mix cinder.gen.collection MyAppWeb.GuidesLive MyApp.Ops.Guide --theme daisy_ui --route /admin/guides
    """
    @shortdoc "Generate (or update) a LiveView with a Cinder collection table for an Ash resource."
    @moduledoc """
    Idempotent generator for a LiveView that renders a `<Cinder.collection>`
    of an Ash resource.

    Re-running the task on an existing module re-derives the `render/1`
    template from the resource. The HEEx template is built and validated
    via `MaestroTool.HEExParser` (no regex on closing tags). Module
    splicing is done with `Igniter` + `Sourceror`.

    ## Example

    ```bash
    #{@example}
    ```

    ## Options

    * `--theme` — Cinder theme name (default: `daisy_ui`)
    * `--page-size` — Items per page (default: `25`)
    * `--bulk-actions` — Comma-separated Ash action names to render as
      `<:bulk_action>` slots. **Bulk actions are only emitted when this
      flag is provided.** Per-app default is no selection / no slots.
      Each named action must already exist on the resource.
    * `--route` — Route path to print as a copy/paste reminder (does
      not edit your router yet)
    * `--action` — Ash read action to use (default: primary read)

    ## Idempotency contract

    - Module doesn't exist → creates it.
    - Module exists, no `render/1` → splices one in.
    - Module exists, `render/1` matches generated → no-op.
    - Module exists, `render/1` differs → replaces it (re-generated from
      resource truth).

    The resource is the source of truth. Don't hand-edit columns; change
    the resource and re-run.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        positional: [:live_view, :resource],
        example: @example,
        schema: [
          theme: :string,
          page_size: :integer,
          bulk_actions: :string,
          route: :string,
          action: :string,
          report_handrolls: :boolean
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      %{live_view: lv_arg, resource: resource_arg} = igniter.args.positional
      opts = igniter.args.options

      lv_module = Igniter.Project.Module.parse(lv_arg)
      resource = Igniter.Project.Module.parse(resource_arg)

      ensure_resource_compiled!(resource)

      cond do
        Keyword.get(opts, :report_handrolls, false) ->
          report_handrolls(igniter, lv_module, resource)

        true ->
          template = build_template(resource, opts)
          validate_template!(template)

          igniter
          |> upsert_live_view(lv_module, resource, template)
          |> maybe_print_route_hint(opts, lv_arg)
      end
    end

    # --- Handroll detection (read-only report) ---

    @doc false
    def report_handrolls(igniter, lv_module, resource) do
      case Igniter.Project.Module.module_exists(igniter, lv_module) do
        {false, igniter} ->
          Igniter.add_notice(
            igniter,
            "#{inspect(lv_module)} does not exist yet — nothing to report."
          )

        {true, igniter} ->
          path = Igniter.Project.Module.proper_location(igniter, lv_module)
          source = File.read!(path)

          case Sourceror.parse_string(source) do
            {:error, _} ->
              Igniter.add_warning(igniter, "Could not parse #{path}")

            {:ok, ast} ->
              violations =
                MaestroTool.Lint.Checks.HandrolledCinderBulk.check(ast, %{
                  path: path,
                  source: source
                })

              if violations == [] do
                Igniter.add_notice(igniter, "No handrolled bulk actions in #{path}.")
              else
                report_lines = build_handroll_report(violations, ast, resource, path)
                Igniter.add_notice(igniter, report_lines)
              end
          end
      end
    end

    # For each violation line, find the surrounding handle_event clause
    # and infer the would-be bulk-action conversion.
    defp build_handroll_report(violations, ast, resource, path) do
      handlers = collect_handle_event_handrolls(ast)

      header = "Handrolled bulk actions in #{path}:\n"

      body =
        Enum.map_join(violations, "\n", fn v ->
          handler = Enum.find(handlers, fn h -> abs(h.line - v.line) <= 4 end)
          format_handroll(v, handler, resource)
        end)

      header <> body
    end

    defp format_handroll(v, nil, _resource) do
      "  - line #{v.line}: handroll detected; could not match to a handle_event clause"
    end

    defp format_handroll(v, handler, resource) do
      action_atom = action_atom_from_event(handler.event)
      actions_index = MapSet.new(Ash.Resource.Info.actions(resource), & &1.name)
      action_status =
        cond do
          handler.kind == :destroy -> "uses :destroy (already exists)"
          MapSet.member?(actions_index, action_atom) -> "action :#{action_atom} exists on #{inspect(resource)}"
          true -> "would need new action :#{action_atom} on #{inspect(resource)}"
        end

      """
        - line #{v.line}: handle_event "#{handler.event}"
            kind: #{handler.kind}
            inferred action: :#{handler.kind == :destroy && "destroy" || action_atom}
            on resource: #{action_status}
            success message: :#{success_atom(action_atom)}
            error message: :#{error_atom(action_atom)}\
      """
    end

    # Walk for `def handle_event(<name>_selected, _params, socket) do ... end`
    # whose body matches the handroll pattern; for each, capture event name,
    # body shape (destroy / update with action atom / unknown), and line.
    defp collect_handle_event_handrolls(ast) do
      {_, handlers} =
        Macro.prewalk(ast, [], fn
          {:def, m,
           [
             {:handle_event, _, [event_str, _params, _socket]},
             [{{:__block__, _, [:do]}, body}]
           ]} = node,
          acc
          when is_binary(event_str) ->
            handle_def_node(node, m, event_str, body, acc)

          # Sourceror sometimes represents the string differently
          {:def, m, [{:handle_event, _, args}, [do: body]]} = node, acc ->
            case args do
              [event, _params, _socket] ->
                event_str = unwrap_string(event)

                if is_binary(event_str) do
                  handle_def_node(node, m, event_str, body, acc)
                else
                  {node, acc}
                end

              _ ->
                {node, acc}
            end

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(handlers)
    end

    defp handle_def_node(node, m, event_str, body, acc) do
      kind = classify_handler_body(body)

      if kind != :not_handroll and String.ends_with?(event_str, "_selected") do
        {node, [%{event: event_str, line: m[:line] || 1, kind: kind} | acc]}
      else
        {node, acc}
      end
    end

    defp unwrap_string({:__block__, _, [str]}) when is_binary(str), do: str
    defp unwrap_string(str) when is_binary(str), do: str
    defp unwrap_string(_), do: nil

    # Decide if the handler body looks like a handrolled bulk action and
    # infer whether the inner work is a destroy or an update.
    defp classify_handler_body(body) do
      destroy? = ast_contains_call?(body, [:Ash], :destroy)
      update? = ast_contains_call?(body, [:Ash], :update)

      cond do
        destroy? -> :destroy
        update? -> :update
        true -> :not_handroll
      end
    end

    defp ast_contains_call?(ast, target_aliases, target_func) do
      {_, found?} =
        Macro.prewalk(ast, false, fn
          {{:., _, [{:__aliases__, _, ^target_aliases}, ^target_func]}, _, _} = node, _ ->
            {node, true}

          node, acc ->
            {node, acc}
        end)

      found?
    end

    # Map "approve_selected" → :approve, "mark_inactive_selected" → :mark_inactive
    defp action_atom_from_event(event_str) do
      event_str
      |> String.trim_trailing("_selected")
      |> String.to_atom()
    end

    defp success_atom(:destroy), do: :deleted
    defp success_atom(action), do: String.to_atom(Atom.to_string(action) <> "d")

    defp error_atom(:destroy), do: :delete_failed
    defp error_atom(action), do: String.to_atom(Atom.to_string(action) <> "_failed")

    # --- Resource introspection ---

    defp ensure_resource_compiled!(resource) do
      unless Code.ensure_loaded?(resource) do
        Mix.raise("""
        Resource #{inspect(resource)} not loaded. Make sure it compiles before running this task.
        """)
      end

      unless Spark.Dsl.is?(resource, Ash.Resource) do
        Mix.raise("""
        #{inspect(resource)} is not an Ash.Resource.
        """)
      end
    end

    defp public_attributes(resource) do
      resource
      |> Ash.Resource.Info.public_attributes()
      |> Enum.reject(&(&1.name in [:id, :inserted_at, :updated_at]))
    end

    defp validate_bulk_actions!(resource, bulk_action_names) do
      action_set =
        resource
        |> Ash.Resource.Info.actions()
        |> MapSet.new(& &1.name)

      missing = Enum.reject(bulk_action_names, &MapSet.member?(action_set, &1))

      if missing != [] do
        Mix.raise("""
        --bulk-actions referenced action(s) that don't exist on #{inspect(resource)}: #{inspect(missing)}.
        Add them to the resource first, then re-run.
        """)
      end

      bulk_action_names
    end

    # --- Template construction ---

    defp build_template(resource, opts) do
      theme = Keyword.get(opts, :theme, "daisy_ui")
      page_size = Keyword.get(opts, :page_size, 25)
      action = Keyword.get(opts, :action)

      bulk_action_names =
        case Keyword.get(opts, :bulk_actions) do
          nil ->
            []

          csv ->
            csv
            |> String.split(",", trim: true)
            |> Enum.map(&String.to_atom(String.trim(&1)))
            |> then(&validate_bulk_actions!(resource, &1))
        end

      attrs = public_attributes(resource)
      let_var = let_var_for(resource)

      cols_iodata =
        Enum.map_join(attrs, "\n", fn attr ->
          filter = filter_attr(attr)
          sort = if sortable?(attr), do: " sort", else: ""

          ~s|        <:col :let={#{let_var}} field="#{attr.name}"#{filter}#{sort}>{#{let_var}.#{attr.name}}</:col>|
        end)

      bulk_iodata =
        case bulk_action_names do
          [] ->
            ""

          actions ->
            actions
            |> Enum.map_join("\n", fn name ->
              ~s|        <:bulk_action action={:#{name}} label="#{humanize(name)} ({count})" />|
            end)
            |> Kernel.<>("\n")
        end

      selectable_attr = if bulk_action_names == [], do: "", else: "\n          selectable"
      action_attr = if action, do: "\n          action={:#{action}}", else: ""

      """
      <Cinder.collection
          id="#{table_id(resource)}"
          resource={#{inspect(resource)}}
          actor={@current_user}
          page_size={#{page_size}}
          theme="#{theme}"
          url_state={@url_state}#{selectable_attr}#{action_attr}
        >
      #{bulk_iodata}#{cols_iodata}
        </Cinder.collection>\
      """
    end

    defp let_var_for(resource), do: resource |> Module.split() |> List.last() |> Macro.underscore()
    defp table_id(resource), do: let_var_for(resource) <> "-table"

    defp humanize(name) when is_atom(name) do
      name
      |> Atom.to_string()
      |> String.replace("_", " ")
      |> String.capitalize()
    end

    defp filter_attr(%{type: Ash.Type.Atom, constraints: c}) do
      if c[:one_of], do: " filter={:select}", else: " filter"
    end

    defp filter_attr(%{type: Ash.Type.Boolean}), do: " filter={:boolean}"
    defp filter_attr(%{type: Ash.Type.String}), do: " filter"
    defp filter_attr(_), do: ""

    defp sortable?(%{type: type}) do
      type in [Ash.Type.String, Ash.Type.Integer, Ash.Type.Atom, Ash.Type.DateTime, Ash.Type.UtcDatetimeUsec, Ash.Type.Date]
    end

    # Validates we produced parseable HEEx. No regex; uses the LV
    # tokenizer via maestro_tool's HEExParser.
    defp validate_template!(template) do
      case MaestroTool.HEExParser.parse(template) do
        {:ok, _tree} ->
          :ok

        {:error, message} ->
          Mix.raise("""
          Generated HEEx failed to parse: #{message}

          Template:
          #{template}
          """)
      end
    end

    # --- Module upsert via Igniter ---

    defp upsert_live_view(igniter, lv_module, resource, template) do
      web_module = web_module_for(lv_module)

      case Igniter.Project.Module.module_exists(igniter, lv_module) do
        {true, igniter} ->
          # Module exists — replace render/1 with our generated one
          Igniter.Project.Module.find_and_update_module!(igniter, lv_module, fn zipper ->
            replace_or_insert_render(zipper, template)
          end)

        {false, igniter} ->
          Igniter.Project.Module.create_module(
            igniter,
            lv_module,
            new_module_body(web_module, resource, template)
          )
      end
    end

    defp web_module_for(lv_module) do
      [base | _] = Module.split(lv_module)
      if String.ends_with?(base, "Web"), do: Module.concat([base]), else: Module.concat([base <> "Web"])
    end

    defp new_module_body(web_module, resource, template) do
      """
      use #{inspect(web_module)}, :live_view
      use Cinder.UrlSync

      @impl true
      def mount(_params, _session, socket) do
        {:ok, socket}
      end

      @impl true
      def handle_params(params, uri, socket) do
        socket = Cinder.UrlSync.handle_params(params, uri, socket)
        {:noreply, socket}
      end

      @impl true
      def render(assigns) do
        ~H\"\"\"
        <Layouts.app flash={@flash} current_user={@current_user}>
      #{indent(template, "    ")}
        </Layouts.app>
        \"\"\"
      end

      # Resource: #{inspect(resource)}
      """
    end

    defp indent(text, prefix) do
      text
      |> String.split("\n")
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> prefix <> line
      end)
    end

    # AST surgery: find `def render(assigns) do ~H"""...""" end`, replace
    # the sigil body with our template; if not found, append a render/1
    # function. No string surgery on the surrounding module.
    defp replace_or_insert_render(zipper, template) do
      case Igniter.Code.Function.move_to_def(zipper, :render, 1) do
        {:ok, render_zipper} ->
          {:ok, replace_render_body(render_zipper, template)}

        :error ->
          {:ok,
           Igniter.Code.Common.add_code(
             zipper,
             Sourceror.parse_string!("""
             @impl true
             def render(assigns) do
               ~H\"\"\"
             #{indent(template, "  ")}
               \"\"\"
             end
             """)
           )}
      end
    end

    # Replace the body of an existing render/1 function. We swap the
    # entire body (the `do` block) with one that contains our regenerated
    # H sigil. Using Sourceror replace keeps everything else intact.
    defp replace_render_body(render_zipper, template) do
      new_body =
        Sourceror.parse_string!("""
        def render(assigns) do
          ~H\"\"\"
        #{indent(template, "  ")}
          \"\"\"
        end
        """)

      Sourceror.Zipper.replace(render_zipper, new_body)
    end

    defp maybe_print_route_hint(igniter, opts, lv_arg) do
      case Keyword.get(opts, :route) do
        nil ->
          igniter

        path ->
          Igniter.add_notice(
            igniter,
            ~s|Add to your router: live "#{path}", #{lv_arg}|
          )
      end
    end
  end
end
