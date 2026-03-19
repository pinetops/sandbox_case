# SandboxCase

Batteries-included test isolation for Elixir and Phoenix.

One config, one setup call, zero boilerplate. Built-in adapters for Ecto, Cachex, FunWithFlags, Mimic, and Mox — each activated only if the dep is loaded.

## Installation

```elixir
{:sandbox_case, "~> 0.1"}
```

## Configuration

```elixir
# config/test.exs
config :sandbox_case,
  otp_app: :my_app,
  mox_mocks: [MyApp.MockWeather],
  sandbox: [
    ecto: true,
    cachex: [:my_cache],
    fun_with_flags: true,
    mimic: [MyApp.ExternalService, MyApp.Payments],
    mox: [{MyApp.MockWeather, MyApp.WeatherBehaviour}]
  ]
```

## Setup

```elixir
# test/test_helper.exs
SandboxCase.Sandbox.setup()
ExUnit.start()
```

## Endpoint and LiveView

```elixir
# lib/your_app_web/endpoint.ex
import SandboxCase
sandbox_plugs()

socket_with_sandbox "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]]
```

```elixir
# lib/your_app_web.ex
def live_view do
  quote do
    use Phoenix.LiveView
    import SandboxCase
    sandbox_on_mount()
  end
end
```

Outside test env, both macros emit nothing.

## Test modules

```elixir
use SandboxCase.Sandbox.Case
```

Checks out all sandboxes in `setup`, checks them back in via `on_exit`. Ecto metadata for browser sessions:

```elixir
SandboxCase.Sandbox.ecto_metadata(context.sandbox_tokens)
```

## Custom adapters

Implement `SandboxCase.Sandbox.Adapter`:

```elixir
config :sandbox_case,
  sandbox: [
    {MyApp.RedisSandbox, pool_size: 4}
  ]
```

## License

MIT
