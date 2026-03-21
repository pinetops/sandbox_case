defmodule SandboxCase.Sandbox do
  @moduledoc """
  Orchestrates test sandbox setup and per-test checkout/checkin.

  ## Setup

  Call once in `test/test_helper.exs`:

      SandboxCase.Sandbox.setup()

  This reads config and runs each adapter's `setup/1`.

  ## Configuration

      # config/test.exs
      config :sandbox_case,
        otp_app: :my_app,
        sandbox: [
          ecto: true,                              # auto-discovers repos from otp_app
          cachex: [:my_cache],                     # cache names to sandbox
          fun_with_flags: true,                    # enable FWF sandbox pool
          mimic: [MyApp.External, MyApp.Payments], # modules to Mimic.copy
          mox: [{MyApp.MockWeather, MyApp.WeatherBehaviour}],
          redis: [url: "redis://localhost:6379"]
        ]

  Each key maps to a built-in adapter. You can also pass custom adapters:

      config :sandbox_case,
        sandbox: [
          {MyApp.CustomSandbox, [some: :config]}
        ]

  ## Per-test checkout

  Use the case template:

      use SandboxCase.Sandbox.Case

  Or call manually:

      tokens = SandboxCase.Sandbox.checkout()
      on_exit(fn -> SandboxCase.Sandbox.checkin(tokens) end)
  """

  @builtin_adapters %{
    ecto: SandboxCase.Sandbox.Ecto,
    cachex: SandboxCase.Sandbox.Cachex,
    fun_with_flags: SandboxCase.Sandbox.FunWithFlags,
    mimic: SandboxCase.Sandbox.Mimic,
    mox: SandboxCase.Sandbox.Mox,
    redis: SandboxCase.Sandbox.Redis,
    logger: SandboxCase.Sandbox.Logger,
  }

  @doc """
  One-time setup. Call from test_helper.exs.
  """
  def setup(opts \\ []) do
    for {adapter, config} <- resolved_adapters(opts) do
      adapter.setup(config)
    end

    sandbox_config = opts[:sandbox] || Application.get_env(:sandbox_case, :sandbox, [])

    if dd_config = sandbox_config[:deadlock_detector] do
      config = if is_list(dd_config), do: dd_config, else: []
      SandboxCase.Sandbox.DeadlockDetector.setup(config)
    end

    :ok
  end

  @doc """
  Per-test checkout. Returns a map with `:owner` (the test pid) and
  `:tokens` (a list of `{adapter, token}` tuples).
  Pass the whole map to `checkin/1` in `on_exit`.
  """
  def checkout(opts \\ []) do
    async? = Keyword.get(opts, :async?, false)

    tokens =
      for {adapter, config} <- resolved_adapters(opts) do
        config = if Keyword.keyword?(config), do: Keyword.put(config, :async?, async?), else: config
        {adapter, adapter.checkout(config)}
      end

    %{owner: self(), tokens: tokens}
  end

  @doc """
  Per-test checkin. Order matters:
  1. Wait for orphans to finish naturally
  2. Rollback Ecto sandbox (stuck queries fail cleanly, connections stay healthy)
  3. Brief wait for rollback-triggered process deaths
  4. Kill any remaining orphans
  5. Check unconsumed logs + checkin remaining adapters
  """
  def checkin(%{owner: owner, tokens: tokens}) do
    await_orphans(owner)

    # Rollback Ecto first — stuck queries fail with rollback error,
    # not connection death. Error logs are still captured (Logger
    # hasn't checked in yet).
    {ecto_tokens, other_tokens} =
      Enum.split_with(tokens, fn {adapter, _} ->
        adapter == SandboxCase.Sandbox.Ecto
      end)

    for {adapter, token} <- ecto_tokens do
      adapter.checkin(token)
    end

    # Brief wait for rollback-triggered deaths, then kill survivors
    if ecto_tokens != [], do: Process.sleep(50)
    kill_orphans(owner)

    # Now check logs + checkin remaining adapters
    for {adapter, token} <- other_tokens do
      adapter.checkin(token)
    end

    :ok
  end

  @orphan_timeout 5_000

  @doc """
  Wait for orphaned processes to finish naturally (up to timeout).
  Does NOT kill survivors — call `kill_orphans/1` separately.
  """
  def await_orphans(owner, timeout \\ @orphan_timeout) do
    orphans = find_orphans(owner)

    if orphans != [] do
      refs =
        Enum.map(orphans, fn pid ->
          {pid, Process.monitor(pid)}
        end)

      deadline = System.monotonic_time(:millisecond) + timeout

      for {_pid, ref} <- refs do
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          remaining -> Process.demonitor(ref, [:flush])
        end
      end
    end

    :ok
  end

  @doc """
  Find and kill orphaned processes immediately (no waiting).
  """
  def kill_orphans(owner) do
    orphans = find_orphans(owner)

    if orphans != [] do
      info =
        Enum.map_join(orphans, "\n  ", fn pid ->
          name = process_name(pid)
          if name, do: "#{inspect(pid)} (#{name})", else: inspect(pid)
        end)

      IO.warn(
        "SandboxCase: killing #{length(orphans)} orphaned process(es) that outlived the test:\n  #{info}"
      )

      for pid <- orphans do
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end
    end

    :ok
  end

  defp find_orphans(owner) do
    self_pid = self()

    Process.list()
    |> Enum.filter(fn pid ->
      pid != self_pid and pid != owner and spawned_by_test?(pid, owner)
    end)
  end

  # An orphan is a process that has the test pid in its $callers
  # but is NOT part of a system supervision tree. OTP sets $ancestors
  # for supervised processes — but if the ancestor is the test pid
  # itself, it's a test-spawned process (e.g. Task.start), not a
  # system process.
  defp spawned_by_test?(pid, owner) do
    case :erlang.process_info(pid, :dictionary) do
      {:dictionary, dict} ->
        has_caller = case List.keyfind(dict, :"$callers", 0) do
          {:"$callers", callers} -> owner in callers
          _ -> false
        end

        system_supervised = case List.keyfind(dict, :"$ancestors", 0) do
          {:"$ancestors", ancestors} -> not (owner in ancestors)
          _ -> false
        end

        has_caller and not system_supervised

      _ ->
        false
    end
  catch
    _, _ -> false
  end

  defp process_name(pid) do
    case :erlang.process_info(pid, :registered_name) do
      {:registered_name, name} -> name
      _ -> nil
    end
  catch
    _, _ -> nil
  end

  @doc """
  Returns the Ecto metadata from the most recent checkout, if any.
  Useful for passing to browser session start.
  """
  def ecto_metadata(%{tokens: tokens}), do: ecto_metadata(tokens)

  def ecto_metadata(tokens) when is_list(tokens) do
    case List.keyfind(tokens, SandboxCase.Sandbox.Ecto, 0) do
      {_, %{metadata: metadata}} -> metadata
      _ -> nil
    end
  end

  @doc """
  Build a `Plug.Conn` with sandbox metadata encoded in the user-agent.

  Use this instead of `Phoenix.ConnTest.build_conn()` when your endpoint
  has `server: true` — the metadata allows the Plug to propagate sandbox
  state (Ecto, Mimic, Mox, Cachex, FunWithFlags, Logger) to the Bandit
  handler process.

  With `server: false`, `Phoenix.ConnTest.build_conn()` works fine since
  requests are dispatched inline in the test process.
  """
  def build_conn(sandbox) do
    conn = Phoenix.ConnTest.build_conn()

    case ecto_metadata(sandbox) do
      nil -> conn
      metadata ->
        ua = Phoenix.Ecto.SQL.Sandbox.encode_metadata(metadata)
        Plug.Conn.put_req_header(conn, "user-agent", ua)
    end
  end

  @doc """
  Collects all plug modules declared by available adapters.
  Used by `SandboxCase.sandbox_plugs/0` at compile time.
  """
  def collect_plugs do
    resolved_adapters([])
    |> Enum.flat_map(fn {adapter, _config} ->
      if function_exported?(adapter, :plugs, 0), do: adapter.plugs(), else: []
    end)
    |> Enum.filter(&Code.ensure_loaded?/1)
  end

  @doc """
  Collects all on_mount modules declared by available adapters.
  Used by `SandboxCase.sandbox_on_mount/0` at compile time.
  """
  def collect_hooks do
    resolved_adapters([])
    |> Enum.flat_map(fn {adapter, _config} ->
      if function_exported?(adapter, :hooks, 0), do: adapter.hooks(), else: []
    end)
    |> Enum.filter(&Code.ensure_loaded?/1)
  end

  @doc false
  def propagate_keys do
    resolved_adapters([])
    |> Enum.flat_map(fn {adapter, config} ->
      if function_exported?(adapter, :propagate_keys, 1), do: adapter.propagate_keys(config), else: []
    end)
  end

  defp resolved_adapters(opts) do
    sandbox_config = opts[:sandbox] || Application.get_env(:sandbox_case, :sandbox, [])
    otp_app = opts[:otp_app] || Application.get_env(:sandbox_case, :otp_app)

    sandbox_config
    |> Enum.map(fn entry -> resolve_adapter(entry, otp_app) end)
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_adapter({key, config}, otp_app) when is_atom(key) do
    case Map.get(@builtin_adapters, key) do
      nil ->
        # key is a custom adapter module
        if Code.ensure_loaded?(key) do
          {key, normalize_config(config, otp_app)}
        end

      adapter ->
        if adapter.available?() do
          {adapter, normalize_config(config, otp_app)}
        end
    end
  end

  defp resolve_adapter({adapter, config}, otp_app) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) do
      {adapter, normalize_config(config, otp_app)}
    end
  end

  defp normalize_config(true, otp_app), do: [otp_app: otp_app]

  defp normalize_config(config, otp_app) when is_list(config) do
    if Keyword.keyword?(config) do
      Keyword.put_new(config, :otp_app, otp_app)
    else
      config
    end
  end

  defp normalize_config(config, _otp_app), do: config
end
