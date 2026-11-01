# SPDX-FileCopyrightText: 2025 Cinder contributors <https://github.com/sevenseacat/cinder/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Cinder do
  @moduledoc """
  Tables, lists and grids of Ash resources in Phoenix LiveView, with filtering, sorting, search
  and pagination.

  ```heex
  <Cinder.collection resource={MyApp.User} actor={@current_user}>
    <:col :let={user} field="name" filter sort>{user.name}</:col>
    <:col :let={user} field="email" filter>{user.email}</:col>
  </Cinder.collection>
  ```

  For a list or grid, describe each item with an `<:item>` slot:

  ```heex
  <Cinder.collection resource={MyApp.User} actor={@current_user} layout={:grid}>
    <:col field="name" filter sort />
    <:item :let={user}>
      <div class="p-4 border rounded">{user.name}</div>
    </:item>
  </Cinder.collection>
  ```

  This module holds the component, `collection/1` (see `Cinder.Collection` for its attributes),
  and functions for changing a collection from your LiveView:

  - `refresh_table/2,3` and `refresh_tables/2,3` re-read collections.
  - `update_item/4`, `update_items/4`, `update_if_visible/4` and `update_items_if_visible/4` change
    rows on screen without re-reading.
  - `remove_item/3` and `remove_items/3` take rows off the page.

  See the [Getting Started](getting-started.html) guide to begin, and
  [Custom Filters](custom-filters.html) to write your own filter types.
  """

  # Unified collection component
  defdelegate collection(assigns), to: Cinder.Collection

  # Refresh functions
  defdelegate refresh_table(socket, table_id), to: Cinder.Refresh
  defdelegate refresh_table(socket, table_id, opts), to: Cinder.Refresh
  defdelegate refresh_tables(socket, table_ids), to: Cinder.Refresh
  defdelegate refresh_tables(socket, table_ids, opts), to: Cinder.Refresh

  # In-memory change functions (efficient for small PubSub-driven changes)
  defdelegate update_item(socket, collection_id, id, update_fn), to: Cinder.Update
  defdelegate update_items(socket, collection_id, ids, update_fn), to: Cinder.Update
  defdelegate update_if_visible(socket, collection_id, id, update_fn), to: Cinder.Update
  defdelegate update_items_if_visible(socket, collection_id, ids, update_fn), to: Cinder.Update
  defdelegate remove_item(socket, collection_id, id), to: Cinder.Update
  defdelegate remove_items(socket, collection_id, ids), to: Cinder.Update

  @doc """
  Sets up Cinder with configured custom filters.

  This is the recommended way to use custom filters in Cinder. Call this
  function once during application startup to automatically register all
  custom filters defined in your configuration.

  ## Configuration

  Define your custom filters in your application configuration:

      config :cinder, :filters, [
        slider: MyApp.Filters.Slider,
        color_picker: MyApp.Filters.ColorPicker
      ]

  ## Usage

  Call `setup/0` once in your application startup:

      # In your application.ex
      def start(_type, _args) do
        Cinder.setup()  # Registers all configured filters automatically

        children = [
          # ... your application's children
        ]

        opts = [strategy: :one_for_one, name: MyApp.Supervisor]
        Supervisor.start_link(children, opts)
      end

  ## What it does

  - Registers all custom filters from configuration
  - Validates that all filter modules implement the required behavior
  - Provides helpful logging for successful registrations and errors
  - Gracefully handles configuration issues without breaking startup

  ## Returns

  Always returns `:ok`. Any registration issues are logged as warnings
  but don't prevent application startup.

  ## Examples

      # Successful setup with filters
      Cinder.setup()
      # => :ok
      # Logs the `cinder.filters.registered` event with a filter count.

      # Setup with configuration errors
      Cinder.setup()
      # => :ok
      # Logs the `cinder.filters.registration_failed` event with an error count.
  """
  @deprecated "Custom filters are read from configuration; setup is no longer required"
  def setup do
    case Cinder.Filters.Registry.register_config_filters() do
      :ok ->
        configured_filters = Application.get_env(:cinder, :filters, [])

        if configured_filters != [] do
          require Logger

          Logger.info("Cinder custom filters registered.",
            event: "cinder.filters.registered",
            count: length(configured_filters),
            outcome: "success"
          )
        end

        :ok

      {:error, errors} ->
        require Logger

        Logger.warning("Cinder custom filter registration failed.",
          event: "cinder.filters.registration_failed",
          count: length(errors),
          outcome: "failure",
          reason_code: "invalid_filter_configuration"
        )

        :ok
    end

    # Validate all filters (both config and runtime registered)
    case Cinder.FilterManager.validate_runtime_filters() do
      :ok -> :ok
      # Errors are already logged by validate_runtime_filters
      {:error, _} -> :ok
    end
  end
end
