# SPDX-FileCopyrightText: 2025 Cinder contributors <https://github.com/sevenseacat/cinder/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Cinder.MixProject do
  use Mix.Project

  @version "1.0.0-dev"
  @source_url "https://github.com/sevenseacat/cinder"

  def project do
    [
      app: :cinder,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      consolidate_protocols: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      description: description(),
      name: "Cinder",
      aliases: aliases(),
      maestro: [lint_checks: [Cinder.Lint.Checks.HandrolledCinderBulk]],
      source_url: @source_url,
      dialyzer: [plt_add_apps: [:mix]],
      gettext: [write_reference_line_numbers: false]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp aliases do
    [
      docs: [
        "compile",
        fn _ -> Cinder.Theme.Docs.write_docs!() end,
        "docs",
        &copy_theme_images/1
      ]
    ]
  end

  defp copy_theme_images(_) do
    File.cp_r!("./docs/screenshots", "./doc/screenshots")
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.37 and >= 3.37.4"},
      {:ash_sql, ">= 0.6.3", optional: true},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ash_phoenix, "~> 2.3 and >= 2.3.26"},
      {:phoenix_live_view, "~> 1.2 and >= 1.2.13"},
      {:gettext, "~> 1.0.2"},
      {:usage_rules, "~> 1.3 and >= 1.3.1", only: [:dev]},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:makeup_eex, "~> 2.0 and >= 2.0.2", only: :dev},
      {:makeup_html, ">= 0.0.0", only: :dev},
      {:igniter, "~> 0.8.5", only: [:dev, :test]},
      {:sourceror, "~> 1.13", only: [:dev, :test]},
      {:maestro_tool,
       path: System.get_env("MAESTRO_TOOL_PATH", "../maestro_tool"),
       only: [:dev, :test],
       env: :test},
      {:mimic, "~> 2.5", only: :test},
      {:phoenix_test, "~> 0.14.0", only: :test, runtime: false},
      {:ex_check, "~> 0.17.1", only: [:dev], runtime: false},
      {:credo, "~> 1.7 and >= 1.7.19", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.18.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4 and >= 1.4.9", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Tables, lists and grids of Ash resources in Phoenix LiveView, with filtering, sorting, search and pagination."
  end

  defp package do
    [
      name: "cinder",
      maintainers: ["Rebecca Le <traybaby@gmail.com>"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Website" => "https://cinder.sevenseacat.net"},
      files:
        ~w(lib priv/cinder.css priv/themes i18n .formatter.exs mix.exs README.md CHANGELOG.md LICENSE LICENSES REUSE.toml usage-rules.md)
    ]
  end

  defp docs do
    main? = System.get_env("DOCS_MAIN") == "1"

    [
      main: "readme",
      source_ref: if(main?, do: "main", else: "v#{@version}"),
      before_closing_body_tag: &unreleased_banner(&1, main?),
      source_url: @source_url,
      logo: "logos/buddy-icon.png",
      extras: [
        "README.md",
        "docs/getting-started.md",
        "docs/filters.md",
        "docs/sorting.md",
        "docs/advanced.md",
        "docs/theming.md",
        "docs/theme-showcase.md",
        "docs/custom-filters.md",
        "docs/localization.md",
        "docs/upgrading.md",
        "docs/examples.md",
        "CHANGELOG.md"
      ],
      # They name deprecated functions, which are hidden from the docs
      skip_undefined_reference_warnings_on: ["docs/upgrading.md", "CHANGELOG.md"],
      groups_for_modules: [
        "Core Components": [
          Cinder,
          Cinder.Collection,
          Cinder.Controls,
          Cinder.LiveComponent
        ],
        "URL State Management": [
          Cinder.UrlSync
        ],
        Refresh: [
          Cinder.Refresh,
          Cinder.Update
        ],
        "Filter Types": [
          Cinder.Filter,
          Cinder.Filter.Helpers,
          Cinder.Filter.Debug,
          ~r/Cinder\.Filters\./
        ],
        Renderers: [
          ~r/Cinder\.Renderers\./
        ],
        "Theming System": [
          Cinder.Theme,
          ~r/Cinder\.Theme\./,
          ~r/Cinder\.Themes\./,
          ~r/Cinder\.Components\./
        ],
        Localization: [
          Cinder.Gettext,
          Cinder.Messages
        ],
        "Mix Tasks": [
          ~r/Mix\.Tasks\./
        ],
        Deprecated: [
          Cinder.Table,
          Cinder.Table.UrlSync,
          Cinder.Table.Refresh
        ]
      ]
    ]
  end

  # Docs built from `main` go to GitHub Pages, and mustn't pass for the released docs on hexdocs
  defp unreleased_banner(:html, true) do
    """
    <script>
      document.getElementById("content").insertAdjacentHTML("afterbegin", `
        <section role="note" class="admonition warning">
          <h4 class="admonition-title warning">Unreleased</h4>
          <p>These docs are built from Cinder's <code>main</code> branch.
          For the latest release, see <a href="https://cinder.hexdocs.pm">cinder.hexdocs.pm</a>.</p>
        </section>`)
    </script>
    """
  end

  defp unreleased_banner(_format, _main?), do: ""
end
