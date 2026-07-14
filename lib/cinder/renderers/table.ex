defmodule Cinder.Renderers.Table do
  @moduledoc """
  Renderer for table layout using Phoenix Streams for efficient row updates.

  Rows are rendered inside a `phx-update="stream"` container, which means
  Phoenix only sends diffs for changed rows to the client. When a single
  item is updated via `Cinder.update_item/4`, only that row's DOM is patched —
  the rest of the table is untouched.

  ## DOM structure

      <tbody id="{table-id}-stream" phx-update="stream">
        <tr id="{dom_id}" :for={{dom_id, item} <- @streams.data}>...</tr>
      </tbody>
      <tbody :if={@data == []}>...</tbody>

  Empty and error states render outside the stream container so LiveView can
  replace and reorder stream rows without persistent static children.
  """

  use Phoenix.Component
  use Cinder.Messages

  import Cinder.Renderers.Helpers

  alias Cinder.Renderers.BulkActions
  alias Cinder.Renderers.Pagination
  alias Cinder.Renderers.SortIcon

  @doc """
  Renders the table layout.
  """
  def render(assigns) do
    ~H"""
    <div class={[@theme.container_class, "relative"]} data-key="container_class">
      <%= if Map.get(assigns, :sticky_toolbar, false) do %>
        <.sticky_toolbar assigns={assigns} />
      <% else %>
        <!-- Filter Controls (including search) -->
        <div :if={@show_filters} class={@theme.controls_class} data-key="controls_class">
          <Cinder.FilterManager.render_filter_controls
            table_id={@id}
            columns={Map.get(assigns, :query_columns, @columns)}
            filters={@filters}
            theme={@theme}
            target={@myself}
            filters_label={@filters_label}
            filter_mode={@show_filters}
            search_term={@search_term}
            show_search={@search_enabled}
            search_label={@search_label}
            search_placeholder={@search_placeholder}
            raw_filter_params={Map.get(assigns, :raw_filter_params, %{})}
            controls_slot={Map.get(assigns, :controls_slot, [])}
            default_filters={Map.get(assigns, :default_filters, %{})}
            show_all?={Map.get(assigns, :show_all?, false)}
          />
        </div>

        <!-- Bulk Actions -->
        <BulkActions.render
          selectable={@selectable}
          selected_ids={@selected_ids}
          data={@data}
          id_field={@id_field}
          filtered_count={Map.get(assigns, :filtered_count)}
          bulk_action_slots={@bulk_action_slots}
          theme={@theme}
          myself={@myself}
        />
      <% end %>

      <!-- Main table -->
      <div class={@theme.table_wrapper_class} data-key="table_wrapper_class">
        <table class={@theme.table_class} data-key="table_class">
          <thead class={thead_class(assigns)} data-key="thead_class">
            <tr class={@theme.header_row_class} data-key="header_row_class">
              <th :if={@selectable} class={[@theme.th_class, "w-10"]} data-key="th_class">
                <input
                  id={"#{@id}-select-all-page"}
                  type="checkbox"
                  checked={all_page_selected?(@selected_ids, @data, @id_field)}
                  data-indeterminate={page_selection_indeterminate(@selected_ids, @data, @id_field)}
                  phx-hook="CinderIndeterminateCheckbox"
                  phx-click="toggle_select_all_page"
                  phx-target={@myself}
                  class={@theme.selection_checkbox_class}
                  data-key="selection_checkbox_class"
                />
              </th>
              <th :for={column <- @columns} class={[@theme.th_class, column.class]} data-key="th_class">
                <div :if={column.sortable}
                     class={["cursor-pointer select-none", (@loading && "opacity-75" || "")]}
                     phx-click="toggle_sort"
                     phx-value-key={column.field}
                     phx-target={@myself}>
                     {column.label}
                     <span class={@theme.sort_indicator_class} data-key="sort_indicator_class">
                       <SortIcon.sort_icon sort_direction={Cinder.QueryBuilder.get_sort_direction(@sort_by, column.field)} theme={@theme} loading={@loading} />
                     </span>
                </div>
                <div :if={not column.sortable}>
                  {column.label}
                </div>
              </th>
            </tr>
          </thead>
          <tbody id={"#{@id}-stream"} phx-update="stream" class={[@theme.tbody_class, (@loading && "opacity-75" || "")]} data-key="tbody_class">
            <!-- Stream rows: only changed items are patched -->
            <%= if Map.has_key?(assigns, :streams) do %>
              <tr
                :for={{dom_id, item} <- @streams.data}
                :if={not @error}
                id={dom_id}
                class={get_row_classes(@theme.row_class, Map.get(assigns, :item_class), @row_click, @selectable, @selected_ids, item, @id_field, @theme)}
                data-item-id={to_string(Map.get(item, @id_field))}
                data-key="row_class"
                phx-click={row_click_action(@row_click, @selectable, item, @id_field, @myself)}
              >
                <.data_cells
                  item={item}
                  selectable={@selectable}
                  selected_ids={@selected_ids}
                  id_field={@id_field}
                  myself={@myself}
                  theme={@theme}
                  columns={@columns}
                />
              </tr>
            <% else %>
              <tr
                :for={{dom_id, item} <- table_rows(assigns)}
                :if={not @error}
                id={dom_id}
                class={get_row_classes(@theme.row_class, Map.get(assigns, :item_class), @row_click, @selectable, @selected_ids, item, @id_field, @theme)}
                data-item-id={to_string(Map.get(item, @id_field))}
                data-key="row_class"
                phx-click={row_click_action(@row_click, @selectable, item, @id_field, @myself)}
              >
                <.data_cells
                  item={item}
                  selectable={@selectable}
                  selected_ids={@selected_ids}
                  id_field={@id_field}
                  myself={@myself}
                  theme={@theme}
                  columns={@columns}
                />
              </tr>
            <% end %>
          </tbody>
          <tbody :if={not @loading and not @error and @data == []}>
            <tr id={"#{@id}-empty"}>
              <td colspan={column_count(@columns, @selectable)} class={@theme.empty_class} data-key="empty_class">
                <%= if has_slot?(assigns, :empty_slot) do %>
                  {render_slot(@empty_slot, empty_context(assigns))}
                <% else %>
                  {@empty_message}
                <% end %>
              </td>
            </tr>
          </tbody>
          <tbody :if={@error and not @loading}>
            <tr id={"#{@id}-error"}>
              <td colspan={column_count(@columns, @selectable)} class={@theme.empty_class} data-key="error_class">
                <%= if has_slot?(assigns, :error_slot) do %>
                  {render_slot(@error_slot)}
                <% else %>
                  <div class={@theme.error_container_class} data-key="error_container_class">
                    <span class={@theme.error_message_class} data-key="error_message_class">{@error_message}</span>
                  </div>
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Loading indicator -->
      <div :if={@loading} class={@theme.loading_overlay_class} data-key="loading_overlay_class">
        <%= if has_slot?(assigns, :loading_slot) do %>
          {render_slot(@loading_slot)}
        <% else %>
          <div class={@theme.loading_container_class} data-key="loading_container_class">
            <svg class={@theme.loading_spinner_class} data-key="loading_spinner_class" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
              <circle class={@theme.loading_spinner_circle_class} data-key="loading_spinner_circle_class" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
              <path class={@theme.loading_spinner_path_class} data-key="loading_spinner_path_class" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
            </svg>
            {@loading_message}
          </div>
        <% end %>
      </div>

      <!-- Pagination -->
      <Pagination.render
        page={@page}
        page_size_config={@page_size_config}
        theme={@theme}
        myself={@myself}
        show_pagination={@show_pagination}
        pagination_mode={@pagination_mode}
        id={@id}
        id_suffix="bottom"
      />
    </div>
    """
  end

  defp data_cells(assigns) do
    ~H"""
    <td :if={@selectable} class={[@theme.td_class, "w-10"]} data-key="td_class">
      <input
        type="checkbox"
        checked={item_selected?(@selected_ids, @item, @id_field)}
        phx-click="toggle_select"
        phx-value-id={to_string(Map.get(@item, @id_field))}
        phx-target={@myself}
        class={@theme.selection_checkbox_class}
        data-key="selection_checkbox_class"
      />
    </td>
    <td :for={column <- @columns} class={[@theme.td_class, column.class]} data-key="td_class">
      {render_slot(column.slot, @item)}
    </td>
    """
  end

  defp sticky_toolbar(%{assigns: assigns}) do
    assigns = assigns

    ~H"""
    <div
      class={Map.get(@theme, :table_toolbar_class, "sticky top-0 z-40 flex items-center gap-3 bg-white py-2")}
      data-key="table_toolbar_class"
    >
      <div :if={@show_filters} class="shrink-0" data-key="controls_class">
        <Cinder.FilterManager.render_filter_controls
          table_id={@id}
          columns={Map.get(assigns, :query_columns, @columns)}
          filters={@filters}
          theme={@theme}
          target={@myself}
          filters_label={@filters_label}
          filter_mode={@show_filters}
          search_term={@search_term}
          show_search={@search_enabled}
          search_label={@search_label}
          search_placeholder={@search_placeholder}
          raw_filter_params={Map.get(assigns, :raw_filter_params, %{})}
          controls_slot={Map.get(assigns, :controls_slot, [])}
          default_filters={Map.get(assigns, :default_filters, %{})}
          show_all?={Map.get(assigns, :show_all?, false)}
          compact
        />
      </div>

      <BulkActions.render
        selectable={@selectable}
        selected_ids={@selected_ids}
        data={@data}
        id_field={@id_field}
        filtered_count={Map.get(assigns, :filtered_count)}
        bulk_action_slots={@bulk_action_slots}
        theme={@theme}
        myself={@myself}
        compact
      />

      <div class="ml-auto shrink-0">
        <Pagination.render
          page={@page}
          page_size_config={@page_size_config}
          theme={@theme}
          myself={@myself}
          show_pagination={@show_pagination}
          pagination_mode={@pagination_mode}
          id={@id}
          id_suffix="top"
          compact
        />
      </div>
    </div>
    """
  end

  defp thead_class(%{sticky_toolbar: true, theme: theme}) do
    [theme.thead_class, "cinder-sticky-thead sticky top-28 z-30 bg-base-100 shadow-sm"]
  end

  defp thead_class(%{theme: theme}), do: theme.thead_class

  defp table_rows(assigns) do
    id = Map.get(assigns, :id, "cinder-table")
    id_field = Map.get(assigns, :id_field, :id)

    assigns
    |> Map.get(:data, [])
    |> Enum.map(fn item -> {"#{id}-#{Map.get(item, id_field)}", item} end)
  end

  # ============================================================================
  # HELPER FUNCTIONS
  # ============================================================================

  defp get_row_classes(
         base_classes,
         user_item_class,
         row_click,
         selectable,
         selected_ids,
         item,
         id_field,
         theme
       ) do
    # Merge the per-item user class onto the theme's base row class
    base = [base_classes, resolve_item_class(user_item_class, item)]

    # Add cursor-pointer if row is clickable (either via row_click or selectable without row_click)
    clickable = row_click != nil or (selectable and row_click == nil)
    classes = if clickable, do: base ++ ["cursor-pointer"], else: base

    if selectable and item_selected?(selected_ids, item, id_field) do
      classes ++ [theme.selected_row_class]
    else
      classes
    end
  end

  defp row_click_action(row_click, _selectable, item, _id_field, _myself) when row_click != nil do
    row_click.(item)
  end

  defp row_click_action(nil, true, item, id_field, myself) do
    Phoenix.LiveView.JS.push("toggle_select",
      value: %{id: to_string(Map.get(item, id_field))},
      target: myself
    )
  end

  defp row_click_action(nil, false, _item, _id_field, _myself), do: nil

  defp all_page_selected?(selected_ids, data, id_field) when is_list(data) and data != [] do
    Enum.all?(data, fn item ->
      item_selected?(selected_ids, item, id_field)
    end)
  end

  defp all_page_selected?(_selected_ids, _data, _id_field), do: false

  defp some_page_selected?(selected_ids, data, id_field) when is_list(data) and data != [] do
    Enum.any?(data, fn item ->
      item_selected?(selected_ids, item, id_field)
    end)
  end

  defp some_page_selected?(_selected_ids, _data, _id_field), do: false

  defp page_selection_indeterminate(selected_ids, data, id_field) do
    if some_page_selected?(selected_ids, data, id_field) &&
         !all_page_selected?(selected_ids, data, id_field) do
      "true"
    else
      "false"
    end
  end

  defp item_selected?(selected_ids, item, id_field) do
    id = to_string(Map.get(item, id_field))
    MapSet.member?(selected_ids, id)
  end

  defp column_count(columns, selectable) do
    base_count = length(columns)
    if selectable, do: base_count + 1, else: base_count
  end
end
