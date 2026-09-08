defmodule Cinder.Filter.DebugTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cinder.Filter.Debug

  defmodule FailingFilter do
    def process(input, _column), do: raise("private filter input: #{input}")
  end

  setup do
    previous = Application.get_env(:cinder, :debug_filters)
    Application.put_env(:cinder, :debug_filters, true)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:cinder, :debug_filters)
      else
        Application.put_env(:cinder, :debug_filters, previous)
      end
    end)
  end

  test "failed input diagnostics do not serialize inputs or exception messages" do
    private_input = "secret-customer@example.com"

    log =
      capture_log(fn ->
        Debug.debug_test_inputs(FailingFilter, [{private_input, %{field: "private-note"}}])
      end)

    assert log =~ "Cinder filter input test failed"
    refute log =~ private_input
    refute log =~ "private filter input"
    refute log =~ "private-note"
  end

  test "stable error classification never includes the exception message" do
    error = %RuntimeError{message: "secret-customer@example.com"}

    assert Cinder.Observability.error_kind(error) == "Elixir.RuntimeError"
    refute Cinder.Observability.error_kind(error) =~ "secret-customer@example.com"
  end
end
