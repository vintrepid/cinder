defmodule Cinder.Integration.SharedRecordCollectionsTest do
  use Cinder.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest, only: [get: 2]

  test "the same records can render in two collections and update independently", %{conn: conn} do
    artist = generate(artist(name: "Shared artist"))
    record = generate(album(title: "Shared record", artist_id: artist.id))

    on_exit(fn ->
      Ash.bulk_destroy!(Cinder.Integration.Album, :destroy, %{})
      Ash.bulk_destroy!(Cinder.Integration.Artist, :destroy, %{})
    end)

    path = Cinder.TestLive.Fixture.register(&collections/1)
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#recent-stream", "Shared record")
    assert has_element?(view, "#all-stream", "Shared record")

    Phoenix.LiveView.send_update(view.pid, Cinder.LiveComponent,
      id: "recent",
      __update_item__: {record.id, &Map.put(&1, :title, "Updated preview")}
    )

    assert has_element?(view, "#recent-stream", "Updated preview")
    assert has_element?(view, "#all-stream", "Shared record")
    refute has_element?(view, "#all-stream", "Updated preview")
  end

  defp collections(assigns) do
    ~H"""
    <Cinder.collection id="recent" resource={Cinder.Integration.Album}>
      <:col :let={album} field="title">{album.title}</:col>
    </Cinder.collection>
    <Cinder.collection id="all" resource={Cinder.Integration.Album}>
      <:col :let={album} field="title">{album.title}</:col>
    </Cinder.collection>
    """
  end
end
