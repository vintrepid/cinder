<!--
SPDX-FileCopyrightText: 2025 Cinder contributors <https://github.com/sevenseacat/cinder/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Cinder

Tables, lists and grids of Ash resources in Phoenix LiveView, with filtering, sorting, search and
pagination.

> [!NOTE]
> Cinder 1.0 is being built on `main`, so this branch may not match the released version. For
> the released docs, see [cinder.hexdocs.pm](https://cinder.hexdocs.pm), and for 0.18 fixes, the
> [`0.18-stable`](https://github.com/sevenseacat/cinder/tree/0.18-stable) branch.

```heex
<Cinder.collection resource={MyApp.User} actor={@current_user}>
  <:col :let={user} field="name" filter sort>{user.name}</:col>
  <:col :let={user} field="email" filter>{user.email}</:col>
  <:col :let={user} field="department.name" filter sort>{user.department.name}</:col>
  <:col :let={user} field="settings__country" filter>{user.settings.country}</:col>
</Cinder.collection>
```

Cinder reads your Ash resource to pick each filter's type (enums become selects, dates become
date pickers, and so on), and loads what each column shows, including relationships,
calculations and aggregates.

## Features

- **Table, list and grid layouts**, which share filtering, sorting and pagination
- **Filters** for text, numbers, dates, booleans, enums and arrays, plus your own
- **Search** across any columns you choose
- **Sorting** on one or more columns, with configurable cycles and tiebreakers
- **Pagination**, offset or keyset, with the total counted alongside, in the background, or not at all
- **Relationship and embedded fields**: `department.name`, `settings__country`
- **URL sync**, so filters, sorting and pages can be bookmarked and shared
- **Selection and bulk actions**
- **Refreshing and updating** rows after changes, without reloading the page
- **Themes**: 8 built in, or your own
- **Translations** for nine languages, including English
- **Telemetry** for every load

### Fit Cinder into an application design system

Cinder owns Ash collection behavior—querying, filters, sorting, pagination,
selection, bulk actions, URL state, and persistence. Your application can own
the visual language without copying that behavior or redefining every theme
property.

Extend the closest built-in theme and set one application root class:

```elixir
defmodule MyAppWeb.CinderTheme do
  use Cinder.Theme

  extends(:daisy_ui)
  set :container_class, "app-collection"
end
```

Cinder renderers expose stable `data-key` styling hooks below that root:

```css
.app-collection [data-key="table_wrapper_class"] {
  /* application collection treatment */
}

.app-collection [data-key="pagination_button_class"] {
  /* application pagination treatment */
}
```

This keeps the application's theme adapter small and lets Cinder change its
internal DOM nesting without forcing page-specific CSS. Use
`Cinder.Theme.validate/1` to catch unsupported or mistyped theme properties.

## Installation

With [Igniter](https://hexdocs.pm/igniter):

```bash
mix igniter.install cinder
```

This adds the dependency, sets up Tailwind and the `daisy_ui` theme, and registers Cinder's
LiveView hook. To install by hand, see
[Getting Started](https://cinder.hexdocs.pm/getting-started.html#installation).

## Quick Start

```heex
<Cinder.collection resource={MyApp.User} actor={@current_user}>
  <:col :let={user} field="name" filter sort>{user.name}</:col>
  <:col :let={user} field="email" filter>{user.email}</:col>
  <:col :let={user} field="role" filter>{user.role}</:col>
</Cinder.collection>
```

For a list or grid, describe each item with an `<:item>` slot. The `<:col>` slots then only
configure filtering and sorting:

```heex
<Cinder.collection resource={MyApp.Product} actor={@current_user} layout={:grid} grid_columns={3}>
  <:col field="name" filter sort />
  <:item :let={product}>
    <div class="p-4 border rounded">{product.name}</div>
  </:item>
</Cinder.collection>
```

## Documentation

- **[Getting Started](https://cinder.hexdocs.pm/getting-started.html)**: installation, layouts, columns and themes
- **[Filters](https://cinder.hexdocs.pm/filters.html)**: filter types, search, and laying out the filters yourself
- **[Sorting](https://cinder.hexdocs.pm/sorting.html)**: sort cycles, modes, defaults and tiebreakers
- **[Advanced Features](https://cinder.hexdocs.pm/advanced.html)**: URL sync, relationships, refreshing, pagination, selection and bulk actions, telemetry
- **[Theming](https://cinder.hexdocs.pm/theming.html)**: built-in themes and writing your own
- **[Localization](https://cinder.hexdocs.pm/localization.html)**: translations and your own Gettext backend
- **[Upgrading](https://cinder.hexdocs.pm/upgrading.html)**: what changed in each version, and how to upgrade
- **[API reference](https://cinder.hexdocs.pm/)**

## Roadmap

### Infinite Scroll (Default)

Replace traditional pagination with infinite scroll as the default collection behavior.
Rows load progressively as the user scrolls, eliminating page boundaries entirely.

### Streaming with Ash.stream!

Cinder currently loads data with paginated `Ash.read()` — one page at a time synchronously.
The next evolution combines `Ash.stream!/2` (lazy, cursor-based batches from the database)
with `Phoenix.LiveView.stream/4` (efficient incremental DOM updates):

- **Data layer**: `Ash.stream!` reads in batches of 250 using keyset pagination, returning
  an Elixir `Stream` that never holds the full result set in memory.
- **UI layer**: Each batch is fed to `Phoenix.LiveView.stream_insert/4`, so rows appear
  progressively as they arrive. The page loads instantly; data fills in.
- **Benefits**: Constant memory usage regardless of result size. No blocking page loads.
  Natural fit for real-time feeds, large exports, and infinite scroll.

This is NOT what live_table did — live_table called `Repo.all()` to load everything,
then split the list at the page boundary. The streaming was DOM-only, not data-level.
True `Ash.stream!` + `LiveView.stream` gives both.

## Requirements

- Phoenix LiveView 1.1+
- Ash Framework 3.24.5+
- Elixir 1.17+

## Contributing

`dev/` holds a Phoenix app for trying out Cinder's features by hand: each layout, every filter type, pagination, selection and bulk actions, and the custom slots, with a switcher for the built-in themes. It uses Cinder from this repo, so changes to `lib/` reload in the browser without a restart.

```bash
cd dev
mix setup
iex -S mix phx.server
```

Then visit [localhost:4000](http://localhost:4000). `mix check`, run from the repo root, also runs the dev app's tests.

## License

MIT License - see LICENSE file for details.
