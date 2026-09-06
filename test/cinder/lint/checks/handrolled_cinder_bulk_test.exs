defmodule Cinder.Lint.Checks.HandrolledCinderBulkTest do
  use ExUnit.Case, async: true

  alias Cinder.Lint.Checks.HandrolledCinderBulk

  @source ~S'''
  defmodule ExampleLive do
    def render(assigns) do
      ~H"""
      <Cinder.collection id="guides" resource={Example.Guide} selectable>
        <:col :let={guide} field="name">{guide.name}</:col>
      </Cinder.collection>
      <button phx-click="delete_selected">Delete selected</button>
      """
    end

    def handle_event("delete_selected", _params, socket) do
      count =
        Enum.reduce(socket.assigns.selected_ids, 0, fn id, acc ->
          case Ash.get(Example.Guide, id) do
            {:ok, guide} ->
              Ash.destroy(guide)
              acc + 1

            _ ->
              acc
          end
        end)

      {:noreply, assign(socket, :deleted_count, count)}
    end
  end
  '''

  test "fixes a supported destroy loop through the optional HEEx parser" do
    [violation] = HandrolledCinderBulk.check(nil, %{source: @source})

    fixed = HandrolledCinderBulk.fix(@source, violation)

    assert fixed =~ "<:bulk_action"
    assert fixed =~ "action={:destroy}"
    assert fixed =~ "on_success={:deleted}"
    refute fixed =~ ~s(phx-click="delete_selected")
    refute fixed =~ ~s(def handle_event("delete_selected")
  end
end
