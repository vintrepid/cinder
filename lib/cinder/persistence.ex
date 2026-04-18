defmodule Cinder.Persistence do
  @moduledoc """
  Pluggable persistence for collection state (filters, sort, search, page, etc.).

  When configured, Cinder collections with a `persist_key` will:

  - Load saved state on mount (when the URL has no collection params).
  - Save state whenever it changes (debounced via the LiveView reducer cycle).

  ## Configuration

      # config/config.exs
      config :cinder, persistence: MyApp.CinderPersistence

  ## Adapter contract

      defmodule MyApp.CinderPersistence do
        @behaviour Cinder.Persistence

        @impl true
        def load(_key, nil), do: nil
        def load(key, %MyApp.User{id: user_id}) do
          case MyApp.Lists.get_preference(user_id, key) do
            {:ok, %{state: state}} -> state
            _ -> nil
          end
        end

        @impl true
        def save(_key, nil, _state), do: :ok
        def save(key, %MyApp.User{id: user_id}, state) do
          MyApp.Lists.upsert_preference(user_id, key, state)
          :ok
        end
      end

  `state` is an opaque map of URL-encoded collection state (the same shape
  produced by `Cinder.UrlManager.encode_state/1`). Adapters should treat it
  as a blob.
  """

  @type key :: String.t()
  @type scope :: any()
  @type state :: map()

  @callback load(key, scope) :: state | nil
  @callback save(key, scope, state) :: :ok | {:error, term()}

  @doc """
  Loads persisted state for `key` and `scope`. Returns `nil` when no adapter
  is configured, no scope is supplied, or no state is saved.
  """
  @spec load(key | nil, scope) :: state | nil
  def load(nil, _scope), do: nil
  def load(_key, nil), do: nil

  def load(key, scope) when is_binary(key) do
    with mod when is_atom(mod) and not is_nil(mod) <- adapter() do
      try do
        mod.load(key, scope)
      rescue
        e ->
          require Logger
          Logger.warning("Cinder.Persistence.load failed: #{Exception.message(e)}")
          nil
      end
    end
  end

  @doc """
  Saves state for `key` and `scope`. No-op when no adapter is configured or
  no scope is supplied.
  """
  @spec save(key | nil, scope, state) :: :ok
  def save(nil, _scope, _state), do: :ok
  def save(_key, nil, _state), do: :ok

  def save(key, scope, state) when is_binary(key) and is_map(state) do
    with mod when is_atom(mod) and not is_nil(mod) <- adapter() do
      try do
        mod.save(key, scope, state)
      rescue
        e ->
          require Logger
          Logger.warning("Cinder.Persistence.save failed: #{Exception.message(e)}")
          :ok
      end
    end

    :ok
  end

  defp adapter, do: Application.get_env(:cinder, :persistence)
end
