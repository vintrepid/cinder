defmodule Cinder.Renderers.BulkActions do
  @moduledoc """
  Shared bulk actions component used by Table, List, and Grid renderers.

  Supports themed buttons via `label`/`variant` attributes, or custom rendering
  via inner content. See the [Advanced Features guide](advanced.md#selection--bulk-actions)
  for comprehensive documentation.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS

  @doc """
  Renders bulk action buttons when selectable is enabled and slots are provided.

  ## Required assigns
  - `selectable` - Boolean indicating if selection is enabled
  - `selected_ids` - MapSet of selected record IDs
  - `data` - Current page records, used to distinguish off-page selections
  - `id_field` - Field used as the record identifier
  - `bulk_action_slots` - List of bulk_action slot definitions
  - `theme` - Theme configuration map
  - `myself` - LiveComponent reference for event targeting
  """
  def render(assigns) do
    selectable = Map.get(assigns, :selectable, false)
    slots = Map.get(assigns, :bulk_action_slots, [])

    if selectable and slots != [] do
      render_bulk_actions(assigns)
    else
      ~H""
    end
  end

  defp render_bulk_actions(assigns) do
    selected_ids = Map.get(assigns, :selected_ids, MapSet.new())
    slots = Map.get(assigns, :bulk_action_slots, [])

    assigns =
      assigns
      |> assign(:selected_ids, selected_ids)
      |> assign(:selected_count, MapSet.size(selected_ids))
      |> assign(:off_page_selected_count, off_page_selected_count(assigns, selected_ids))
      |> assign(:slots, slots)

    ~H"""
    <div class={@theme.bulk_actions_container_class} data-key="bulk_actions_container_class">
      <span :if={@off_page_selected_count > 0} class="text-sm opacity-70">
        {@selected_count} selected, {@off_page_selected_count} off this page
      </span>
      <button
        :if={@off_page_selected_count > 0}
        type="button"
        phx-click={JS.push("clear_selection", target: @myself)}
        class={[
          @theme.button_class,
          @theme.button_secondary_class,
          @selected_count == 0 && @theme.button_disabled_class
        ]}
        disabled={@selected_count == 0}
      >
        Clear all selected
      </button>
      <%= for {slot, index} <- Enum.with_index(@slots) do %>
        <span
          phx-click={JS.push("bulk_action_execute", value: %{index: index}, target: @myself)}
          data-confirm={slot[:confirm] && interpolate_text(slot[:confirm], @selected_count)}
          class="contents"
        >
          <%= if has_label?(slot) do %>
            <.themed_button
              theme={@theme}
              label={slot[:label]}
              variant={slot[:variant] || :primary}
              selected_count={@selected_count}
            />
          <% else %>
            {render_slot([slot], %{selected_ids: @selected_ids, selected_count: @selected_count})}
          <% end %>
        </span>
      <% end %>
    </div>
    """
  end

  defp themed_button(assigns) do
    disabled = assigns.selected_count == 0
    label = interpolate_text(assigns.label, assigns.selected_count)

    button_class =
      [
        assigns.theme.button_class,
        variant_class(assigns.theme, assigns.variant),
        disabled && assigns.theme.button_disabled_class
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    assigns =
      assigns
      |> assign(:disabled, disabled)
      |> assign(:label, label)
      |> assign(:button_class, button_class)

    ~H"""
    <button type="button" class={@button_class} disabled={@disabled}>
      {@label}
    </button>
    """
  end

  defp has_label?(slot), do: Map.has_key?(slot, :label) and slot[:label] != nil

  defp variant_class(theme, :primary), do: theme.button_primary_class
  defp variant_class(theme, :secondary), do: theme.button_secondary_class
  defp variant_class(theme, :danger), do: theme.button_danger_class
  defp variant_class(_theme, _), do: nil

  defp interpolate_text(message, count) do
    String.replace(message, "{count}", to_string(count))
  end

  defp off_page_selected_count(assigns, selected_ids) do
    if Map.has_key?(assigns, :data) do
      off_page_selected_count(assigns, selected_ids, Map.get(assigns, :data))
    else
      0
    end
  end

  defp off_page_selected_count(assigns, selected_ids, data) do
    page_ids =
      data
      |> page_ids(Map.get(assigns, :id_field, :id))

    selected_ids
    |> MapSet.difference(page_ids)
    |> MapSet.size()
  end

  defp page_ids(data, id_field) when is_list(data) do
    data
    |> Enum.map(&to_string(Map.get(&1, id_field)))
    |> MapSet.new()
  end

  defp page_ids(_data, _id_field), do: MapSet.new()
end
