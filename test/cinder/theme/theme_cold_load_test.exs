defmodule Cinder.ThemeColdLoadTest do
  use ExUnit.Case, async: false

  test "validates a built-in theme before its module has been loaded" do
    theme = Cinder.Themes.DaisyUI
    :code.purge(theme)
    :code.delete(theme)

    try do
      refute function_exported?(theme, :resolve_theme, 0)
      assert Cinder.Theme.validate(theme) == :ok
    after
      Code.ensure_loaded!(theme)
    end
  end
end
