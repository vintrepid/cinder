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
          action: :string
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

      template = build_template(resource, opts)
      validate_template!(template)

      igniter
      |> upsert_live_view(lv_module, resource, template)
      |> maybe_print_route_hint(opts, lv_arg)
    end

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
