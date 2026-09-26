defmodule Cinder.Selection.Store do
  @moduledoc """
  Pluggable storage for a user's absolute collection selection.

  Cinder owns selection gestures, while the host application owns the durable
  collection and authorization. A store reads and replaces only the IDs for
  one Ash resource subject; other resource types in the same working
  collection remain untouched.

  Configure a default store with:

      config :cinder, selection_store: MyApp.SelectionStore

  Collections use their Ash resource module as the default subject and their
  existing `persist_scope` as the actor/owner scope. Both may be overridden
  with `selection_store` and `selection_subject`.
  """

  @type scope :: any()
  @type subject :: String.t()
  @type selected_ids :: MapSet.t(String.t())

  @callback load(scope, subject) :: Enumerable.t() | nil
  @callback replace(scope, subject, selected_ids) :: :ok | {:error, term()}

  @doc "Loads the selected IDs for one subject as a `MapSet`."
  @spec load(module() | nil, scope, subject | nil) :: selected_ids
  def load(_store, nil, _subject), do: MapSet.new()
  def load(_store, _scope, nil), do: MapSet.new()

  def load(store, scope, subject) when is_atom(store) and is_binary(subject) do
    try do
      case store.load(scope, subject) do
        nil -> MapSet.new()
        selected_ids -> selected_ids |> Enum.map(&to_string/1) |> MapSet.new()
      end
    rescue
      error ->
        log_failure(:load, store, error)
        MapSet.new()
    end
  end

  def load(_store, _scope, _subject), do: MapSet.new()

  @doc "Replaces the selected IDs for one subject."
  @spec replace(module() | nil, scope, subject | nil, selected_ids) :: :ok
  def replace(_store, nil, _subject, _selected_ids), do: :ok
  def replace(_store, _scope, nil, _selected_ids), do: :ok

  def replace(store, scope, subject, %MapSet{} = selected_ids)
      when is_atom(store) and is_binary(subject) do
    try do
      store.replace(scope, subject, selected_ids)
      :ok
    rescue
      error ->
        log_failure(:replace, store, error)
        :ok
    end
  end

  def replace(_store, _scope, _subject, _selected_ids), do: :ok

  defp log_failure(operation, store, error) do
    require Logger

    Logger.warning("Cinder absolute selection persistence failed.",
      event: "cinder.selection.persistence_failed",
      operation: to_string(operation),
      module: Cinder.Observability.stable_token(store),
      error_kind: Cinder.Observability.error_kind(error),
      outcome: "failure"
    )
  end
end
