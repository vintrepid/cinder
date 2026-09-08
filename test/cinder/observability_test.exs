defmodule Cinder.ObservabilityTest do
  use ExUnit.Case, async: true

  alias Cinder.Observability

  describe "stable_token/1" do
    test "keeps bounded operational tokens" do
      assert Observability.stable_token(:select) == "select"
      assert Observability.stable_token(Cinder.Filters.Text) == "Elixir.Cinder.Filters.Text"
      assert Observability.stable_token("filter.process/2") == "filter.process/2"
    end

    test "does not pass free-form or identifying text into log metadata" do
      assert Observability.stable_token("customer@example.com") == "unknown"
      assert Observability.stable_token("private customer note") == "unknown"
      assert Observability.stable_token(String.duplicate("a", 513)) == "unknown"
      assert Observability.stable_token(%{private: "value"}) == "unknown"
    end
  end

  describe "error_kind/1" do
    test "retains only an exception module or tuple tag" do
      assert Observability.error_kind(%ArgumentError{message: "private detail"}) ==
               "Elixir.ArgumentError"

      assert Observability.error_kind({:shutdown, "private detail"}) == "shutdown"
      assert Observability.error_kind(:timeout) == "timeout"
    end

    test "does not stringify arbitrary error details" do
      assert Observability.error_kind("customer@example.com") == "unknown"
      assert Observability.error_kind({"private", "detail"}) == "unknown"
    end
  end
end
