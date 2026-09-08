defmodule Cinder.Observability do
  @moduledoc false

  @stable_token ~r/^[A-Za-z0-9][A-Za-z0-9_.:\/-]*$/u
  @max_token_bytes 512

  @doc false
  @spec stable_token(term()) :: String.t()
  def stable_token(value) when is_atom(value), do: value |> Atom.to_string() |> stable_token()

  def stable_token(value) when is_binary(value) do
    if byte_size(value) <= @max_token_bytes and String.valid?(value) and
         Regex.match?(@stable_token, value) do
      value
    else
      "unknown"
    end
  end

  def stable_token(_value), do: "unknown"

  @doc false
  @spec error_kind(term()) :: String.t()
  def error_kind(%{__struct__: module}) when is_atom(module), do: stable_token(module)
  def error_kind({kind, _detail}) when is_atom(kind), do: stable_token(kind)
  def error_kind(kind) when is_atom(kind), do: stable_token(kind)
  def error_kind(_reason), do: "unknown"
end
