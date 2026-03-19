# PhoenixTestOnly

Test sandbox orchestration and compile-time conditional `plug`/`on_mount` for Phoenix apps.

## Installation

```elixir
{:phoenix_test_only, "~> 0.3"}
```

## Sandbox orchestration

One config, one setup call. Adapters for Ecto, Cachex, FunWithFlags, Mimic, and Mox are built in. Each is only activated if the dep is loaded.

```elixir
# config/test.exs
config :phoenix_test_only,
  otp_app: :my_app,
  sandbox: [
    ecto: true,
    cachex: [:my_cache],
    fun_with_flags: true,
    mimic: [MyApp.ExternalService, MyApp.Payments],
    mox: [{MyApp.MockWeather, MyApp.WeatherBehaviour}]
  ]
```

```elixir
# test/test_helper.exs
PhoenixTestOnly.Sandbox.setup()
ExUnit.start()
```

```elixir
# In your test modules
use PhoenixTestOnly.Sandbox.Case
```

The case template checks out all sandboxes in `setup` and checks them back in via `on_exit`. Ecto metadata for browser sessions is available via:

```elixir
PhoenixTestOnly.Sandbox.ecto_metadata(context.sandbox_tokens)
```

### Custom adapters

Implement the `PhoenixTestOnly.Sandbox.Adapter` behaviour:

```elixir
config :phoenix_test_only,
  sandbox: [
    {MyApp.RedisSandbox, pool_size: 4}
  ]
```

## Compile-time conditional plug/on_mount

Phoenix's `plug` and `on_mount` macros are silently ignored when wrapped in `if`. These macros gate on `Mix.env() == :test` at macro expansion time — in a release or in dev/prod, nothing is emitted.

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
