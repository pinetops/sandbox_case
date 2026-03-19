# PhoenixTestOnly

Compile-time conditional `plug` and `on_mount` for test-only modules.

Phoenix's `plug` and `on_mount` macros accumulate module attributes at the top level. When wrapped in `if Application.compile_env(...)`, the call ends up inside a `case` node in the AST and Phoenix silently ignores it.

These macros move the check to **macro expansion time**: they only emit code when `Mix.env() == :test`. In a release (where Mix isn't loaded) or in dev/prod, nothing is emitted.

## Installation

```elixir
{:phoenix_test_only, "~> 0.2"}
```

## Usage

```elixir
# endpoint.ex
import PhoenixTestOnly
plug_if_test Phoenix.Ecto.SQL.Sandbox
plug_if_test Wallabidi.Sandbox.Plug

# your_app_web.ex
def live_view do
  quote do
    use Phoenix.LiveView
    import PhoenixTestOnly
    on_mount_if_test Wallabidi.Sandbox.Hook
  end
end
```

## License

MIT
