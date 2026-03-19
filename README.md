# SandboxCase

Batteries-included test isolation for Elixir and Phoenix.

One config, one setup call, zero boilerplate. Built-in adapters for Ecto, Cachex, FunWithFlags, Mimic, and Mox — each activated only if the dep is loaded.

All macros expand at compile time. Outside `MIX_ENV=test`, `sandbox_plugs` and `sandbox_on_mount` emit nothing, and `socket_with_sandbox` emits a plain `socket` call. No runtime checks, no dead branches, no production dependencies on test libraries.

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

## GenServers and sandbox access

Ecto sandbox, Mimic stubs, and Mox mocks are resolved via `$callers` — a process dictionary key that Elixir's `Task` module sets automatically. `GenServer.start_link` does **not** set it, so a GenServer started from a LiveView or test won't see sandboxed state by default.

The fix: pass `$callers` explicitly when starting the GenServer.

```elixir
defmodule MyApp.PriceServer do
  use GenServer

  def start_supervised(opts \\ []) do
    callers = [self() | Process.get(:"$callers", [])]
    GenServer.start_link(__MODULE__, Keyword.put(opts, :callers, callers))
  end

  @impl true
  def init(opts) do
    if callers = opts[:callers], do: Process.put(:"$callers", callers)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:fetch_price, _from, state) do
    # This works in tests — Mimic finds the test process via $callers,
    # and Ecto finds the sandbox connection the same way.
    price = MyApp.PriceService.fetch_price()
    {:reply, price, state}
  end
end
```

This pattern works for any process you spawn that needs access to the test sandbox: GenServers, Agents, custom processes via `spawn_link`, etc. `Task.start_link` and `Task.async` handle this automatically.

## Custom adapters

Implement `SandboxCase.Sandbox.Adapter` to add isolation for any shared state.

```elixir
defmodule MyApp.RedisSandbox do
  @behaviour SandboxCase.Sandbox.Adapter

  # Is the dep available? Return false to skip this adapter entirely.
  @impl true
  def available?, do: Code.ensure_loaded?(Redix)

  # One-time setup — called from test_helper.exs via SandboxCase.Sandbox.setup().
  # Use this to start pools, create isolation resources, etc.
  @impl true
  def setup(config) do
    pool_size = config[:pool_size] || 4
    # ... start a pool of Redis connections
    :ok
  end

  # Per-test checkout — called in each test's setup.
  # Return an opaque token that will be passed to checkin/1.
  @impl true
  def checkout(_config) do
    # ... claim an isolated Redis DB, flush it
    %{db: db_number}
  end

  # Per-test checkin — called in on_exit.
  @impl true
  def checkin(nil), do: :ok
  def checkin(%{db: db}) do
    # ... release the Redis DB back to the pool
    :ok
  end

  # Optional: plug modules to register in the endpoint.
  # Omit this callback if your adapter doesn't need a plug.
  @impl true
  def plugs, do: []

  # Optional: on_mount modules to register in LiveViews.
  # Omit this callback if your adapter doesn't need a hook.
  @impl true
  def hooks, do: []
end
```

Register it in config:

```elixir
config :sandbox_case,
  sandbox: [
    ecto: true,
    {MyApp.RedisSandbox, pool_size: 4}
  ]
```

The adapter lifecycle:

1. `available?/0` — checked at compile time (for plugs/hooks) and runtime (for setup/checkout). Return `false` to skip.
2. `setup/1` — called once from `SandboxCase.Sandbox.setup()` in test_helper.
3. `checkout/1` — called per test. Returns a token.
4. `checkin/1` — called in `on_exit` with the token from checkout.
5. `plugs/0` — (optional) modules emitted by `sandbox_plugs()`.
6. `hooks/0` — (optional) modules emitted by `sandbox_on_mount()`.

## License

MIT
