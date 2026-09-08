defmodule Cinder.Filter.Debug do
  @moduledoc """
  Debugging tools for custom filter development.

  This module provides utilities to help developers debug and test their custom filters
  during development.

  ## Usage

  Enable debug mode in your configuration:

      config :cinder, debug_filters: true

  Then use the debugging functions in your filter:

      defmodule MyApp.Filters.CustomFilter do
        use Cinder.Filter
        import Cinder.Filter.Debug

        @impl true
        def process(raw_value, column) do
          debug_step("Processing input", %{raw_value: raw_value, column: column})

          result = # ... your processing logic

          debug_step("Process result", %{result: result})
          result
        end
      end

  """

  require Logger

  @doc """
  Logs a privacy-safe debug checkpoint.

  Only logs when debug_filters is enabled in configuration. The supplied
  message and context are deliberately not emitted because filter inputs may
  contain private application data.

  ## Examples

      debug_step("Validating input", %{input: "test", step: 1})

  """
  def debug_step(_message, _context \\ %{}) do
    if debug_enabled?() do
      Logger.debug("Cinder filter debug checkpoint reached.",
        event: "cinder.filter.debug_checkpoint"
      )
    end
  end

  @doc """
  Logs filter callback execution with timing.

  ## Examples

      debug_callback("process/2", fn ->
        # Your callback logic here
        process_implementation(raw_value, column)
      end)

  """
  def debug_callback(callback_name, fun) when is_function(fun, 0) do
    if debug_enabled?() do
      start_time = System.monotonic_time(:microsecond)

      result = fun.()

      end_time = System.monotonic_time(:microsecond)
      duration = end_time - start_time

      Logger.debug("Cinder filter callback completed.",
        event: "cinder.filter.callback_completed",
        operation: Cinder.Observability.stable_token(callback_name),
        duration_ms: duration / 1000,
        outcome: "success"
      )

      result
    else
      fun.()
    end
  end

  @doc """
  Validates and logs filter processing pipeline.

  Useful for debugging the complete flow from raw input to final filter.

  ## Examples

      debug_pipeline("MyFilter", raw_value, column, fn ->
        MyFilter.process(raw_value, column)
      end)

  """
  def debug_pipeline(filter_name, _raw_value, _column, process_fun) do
    if debug_enabled?() do
      Logger.debug("Cinder filter pipeline started.",
        event: "cinder.filter.pipeline_started",
        component: Cinder.Observability.stable_token(filter_name),
        outcome: "started"
      )

      result = debug_callback(filter_name, process_fun)

      Logger.debug("Cinder filter pipeline completed.",
        event: "cinder.filter.pipeline_completed",
        component: Cinder.Observability.stable_token(filter_name),
        outcome: "success"
      )

      result
    else
      process_fun.()
    end
  end

  @doc """
  Validates a filter's callbacks and logs any issues.

  Useful during development to ensure all callbacks are properly implemented.

  ## Examples

      debug_validate_filter(MyApp.Filters.CustomFilter)

  """
  def debug_validate_filter(module) when is_atom(module) do
    if debug_enabled?() do
      Logger.debug("Cinder filter validation started.",
        event: "cinder.filter.validation_started",
        module: Cinder.Observability.stable_token(module),
        outcome: "started"
      )

      case Cinder.Filter.Helpers.validate_filter_implementation(module) do
        {:ok, _message} ->
          Logger.debug("Cinder filter validation completed.",
            event: "cinder.filter.validation_completed",
            module: Cinder.Observability.stable_token(module),
            outcome: "success"
          )

          :ok

        {:error, errors} ->
          Logger.error("Cinder filter validation failed.",
            event: "cinder.filter.validation_failed",
            module: Cinder.Observability.stable_token(module),
            count: length(errors),
            outcome: "failure",
            reason_code: "invalid_filter_implementation"
          )

          {:error, errors}
      end
    else
      :ok
    end
  end

  @doc """
  Tests filter processing with sample inputs and logs results.

  Useful for quick testing during development.

  ## Examples

      debug_test_inputs(MyApp.Filters.Slider, [
        {"50", %{filter_options: [min: 0, max: 100]}},
        {"invalid", %{filter_options: []}},
        {"", %{filter_options: []}}
      ])

  """
  def debug_test_inputs(module, test_cases) when is_atom(module) and is_list(test_cases) do
    if debug_enabled?() do
      Logger.debug("Cinder filter input tests started.",
        event: "cinder.filter.input_tests_started",
        module: Cinder.Observability.stable_token(module),
        count: length(test_cases),
        outcome: "started"
      )

      Enum.with_index(test_cases, 1)
      |> Enum.each(fn {{input, column}, index} ->
        Logger.debug("Cinder filter input test started.",
          event: "cinder.filter.input_test_started",
          module: Cinder.Observability.stable_token(module),
          count: index,
          outcome: "started"
        )

        try do
          result = module.process(input, column)

          if result do
            module.validate(result)
            module.empty?(result)
          end

          Logger.debug("Cinder filter input test completed.",
            event: "cinder.filter.input_test_completed",
            module: Cinder.Observability.stable_token(module),
            count: index,
            outcome: "success"
          )
        rescue
          error ->
            Logger.error("Cinder filter input test failed.",
              event: "cinder.filter.input_test_failed",
              module: Cinder.Observability.stable_token(module),
              count: index,
              error_kind: Cinder.Observability.error_kind(error),
              outcome: "failure"
            )
        end
      end)
    end
  end

  @doc """
  Analyzes query building performance and logs the results.

  ## Examples

      debug_query_building(MyApp.Filters.Slider, "price", %{
        type: :slider,
        value: 100,
        operator: :less_than_or_equal
      })

  """
  def debug_query_building(module, field, filter_value) when is_atom(module) do
    if debug_enabled?() do
      Logger.debug("Cinder filter query build started.",
        event: "cinder.filter.query_build_started",
        module: Cinder.Observability.stable_token(module),
        outcome: "started"
      )

      # Create a dummy query for testing
      dummy_query = Ash.Query.new(DummyResource)

      start_time = System.monotonic_time(:microsecond)

      try do
        result_query = module.build_query(dummy_query, field, filter_value)

        end_time = System.monotonic_time(:microsecond)
        duration = end_time - start_time

        Logger.debug("Cinder filter query build completed.",
          event: "cinder.filter.query_build_completed",
          module: Cinder.Observability.stable_token(module),
          duration_ms: duration / 1000,
          outcome: "success"
        )

        result_query
      rescue
        error ->
          Logger.error("Cinder filter query build failed.",
            event: "cinder.filter.query_build_failed",
            module: Cinder.Observability.stable_token(module),
            error_kind: Cinder.Observability.error_kind(error),
            outcome: "failure"
          )

          dummy_query
      end
    else
      # In non-debug mode, just return a dummy query
      Ash.Query.new(DummyResource)
    end
  end

  @doc """
  Logs render performance and output size.

  ## Examples

      debug_render_performance(MyApp.Filters.Slider, column, current_value, theme, assigns)

  """
  def debug_render_performance(module, column, current_value, theme, assigns) do
    if debug_enabled?() do
      start_time = System.monotonic_time(:microsecond)

      result = module.render(column, current_value, theme, assigns)

      end_time = System.monotonic_time(:microsecond)
      duration = end_time - start_time

      # Estimate rendered size (approximate)
      rendered_size = result |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_length()

      Logger.debug("Cinder filter render completed.",
        event: "cinder.filter.render_completed",
        module: Cinder.Observability.stable_token(module),
        duration_ms: duration / 1000,
        count: rendered_size,
        outcome: "success"
      )

      result
    else
      module.render(column, current_value, theme, assigns)
    end
  end

  @doc """
  Checks if debug mode is enabled.
  """
  def debug_enabled? do
    Application.get_env(:cinder, :debug_filters, false)
  end

  @doc """
  Enables debug mode for the current session.

  Useful in IEx for temporary debugging.

  ## Examples

      iex> Cinder.Filter.Debug.enable_debug()
      :ok

  """
  def enable_debug do
    Application.put_env(:cinder, :debug_filters, true)

    Logger.info("Cinder filter debug mode enabled.",
      event: "cinder.filter.debug_enabled",
      outcome: "enabled"
    )
  end

  @doc """
  Disables debug mode for the current session.

  ## Examples

      iex> Cinder.Filter.Debug.disable_debug()
      :ok

  """
  def disable_debug do
    Application.put_env(:cinder, :debug_filters, false)

    Logger.info("Cinder filter debug mode disabled.",
      event: "cinder.filter.debug_disabled",
      outcome: "disabled"
    )
  end

  @doc """
  Runs a comprehensive filter test suite.

  Tests all callbacks with various inputs and logs results.

  ## Examples

      debug_comprehensive_test(MyApp.Filters.Slider)

  """
  def debug_comprehensive_test(module) when is_atom(module) do
    if debug_enabled?() do
      Logger.info("Cinder comprehensive filter test started.",
        event: "cinder.filter.comprehensive_test_started",
        module: Cinder.Observability.stable_token(module),
        outcome: "started"
      )

      # Test validation
      debug_validate_filter(module)

      # Test default options
      try do
        module.default_options()

        Logger.debug("Cinder filter default options loaded.",
          event: "cinder.filter.default_options_loaded",
          module: Cinder.Observability.stable_token(module),
          outcome: "success"
        )
      rescue
        error ->
          Logger.error("Cinder filter default options failed.",
            event: "cinder.filter.default_options_failed",
            module: Cinder.Observability.stable_token(module),
            error_kind: Cinder.Observability.error_kind(error),
            outcome: "failure"
          )
      end

      # Test common process inputs
      test_inputs = [
        "",
        nil,
        "valid_input",
        "123",
        "invalid",
        []
      ]

      column = %{filter_options: []}

      Enum.each(test_inputs, fn input ->
        try do
          result = module.process(input, column)

          if result do
            module.validate(result)
            module.empty?(result)

            Logger.debug("Cinder filter process test completed.",
              event: "cinder.filter.process_test_completed",
              module: Cinder.Observability.stable_token(module),
              outcome: "success"
            )
          else
            Logger.debug("Cinder filter process test returned no filter.",
              event: "cinder.filter.process_test_empty",
              module: Cinder.Observability.stable_token(module),
              outcome: "empty"
            )
          end
        rescue
          error ->
            Logger.error("Cinder filter process test failed.",
              event: "cinder.filter.process_test_failed",
              module: Cinder.Observability.stable_token(module),
              error_kind: Cinder.Observability.error_kind(error),
              outcome: "failure"
            )
        end
      end)

      Logger.info("Cinder comprehensive filter test completed.",
        event: "cinder.filter.comprehensive_test_completed",
        module: Cinder.Observability.stable_token(module),
        outcome: "success"
      )
    end
  end

  # Dummy resource for query testing
  defmodule DummyResource do
    @moduledoc false
    use Ash.Resource, data_layer: Ash.DataLayer.Ets, domain: nil

    attributes do
      integer_primary_key(:id)
      attribute(:name, :string)
      attribute(:value, :integer)
      attribute(:active, :boolean)
    end

    actions do
      defaults([:read, :create, :update, :destroy])
    end
  end
end
