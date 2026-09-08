import Config
config :ash, default_string_length_count: :codepoints

# Add your configuration here
config :logger, level: :info

if config_env() == :test do
  import_config "test.exs"
end
