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
    logger: SandboxCase.Sandbox.Logger
  }

  @orphan_timeout 5_000

  @doc """
  One-time setup. Call from test_helper.exs.
  """
  def setup(opts \\ []) do
    Application.put_env(:sandbox_case, :setup_done, true)

    for {adapter, config} <- resolved_adapters(opts) do
      adapter.setup(config)
    end

    sandbox_config = opts[:sandbox] || Application.get_env(:sandbox_case, :sandbox, [])

    if dd_config = sandbox_config[:deadlock_detector] do
      config = if is_list(dd_config), do: dd_config, else: []
      SandboxCase.Sandbox.DeadlockDetector.setup(config)
    end

    if lm_config = sandbox_config[:lock_monitor] do
      config = if is_list(lm_config), do: lm_config, else: []

      # Auto-discover repo if not specified
      config =
        if config[:repo] do
          config
        else
          otp_app = opts[:otp_app] || Application.get_env(:sandbox_case, :otp_app)
          repos = if otp_app, do: Application.get_env(otp_app, :ecto_repos, []), else: []

          case List.first(repos) do
            nil -> config
            repo -> Keyword.put(config, :repo, repo)
          end
        end

      SandboxCase.Sandbox.LockMonitor.start_link(config)
    end

    :ok
  end

  @doc """
  Returns true if `setup/1` has been called.
  """
  def setup? do
    Application.get_env(:sandbox_case, :setup_done, false)
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
        config =
          if Keyword.keyword?(config), do: Keyword.put(config, :async?, async?), else: config

        {adapter, adapter.checkout(config)}
      end

    %{owner: self(), tokens: tokens}
  end

  @doc """
  Register a cleanup callback to run during checkin, before sandbox
  rollback. Use for teardown that triggers processes needing DB access
  (e.g. closing browser sessions that kill LiveViews mid-transaction).

      SandboxCase.Sandbox.on_cleanup(sandbox, fn ->
        Wallabidi.end_session(session)
      end)

  Callbacks run in registration order, before await_orphans.
  OwnershipErrors logged during callbacks are swallowed.
  """
  def on_cleanup(%{owner: _} = _sandbox, fun) when is_function(fun, 0) do
    callbacks = Process.get(:sandbox_case_cleanup_callbacks, [])
    Process.put(:sandbox_case_cleanup_callbacks, callbacks ++ [fun])
  end

  @doc """
  Per-test checkin. Order matters:
  1. Run cleanup callbacks (e.g. close browser sessions)
  2. Wait for orphans to finish naturally
  3. Rollback Ecto sandbox
  4. Kill any remaining orphans
  5. Check unconsumed logs + checkin remaining adapters
  """
  def checkin(%{owner: owner, tokens: tokens}) do
    # Run cleanup callbacks — mark cleanup so OwnershipErrors are swallowed
    callbacks = Process.get(:sandbox_case_cleanup_callbacks, [])

    if callbacks != [] do
      mark_cleanup_started()

      for fun <- callbacks do
        try do
          fun.()
        rescue
          _ -> :ok
        end
      end
    end

    Process.delete(:sandbox_case_cleanup_callbacks)

    orphan_timeout = Process.get(:sandbox_case_orphan_timeout, @orphan_timeout)
    survivors = await_orphans(owner, orphan_timeout)

    # Re-scan for children spawned during await (e.g. Cachex Courier
    # workers triggered by a LiveView message).
    late_children = find_test_children(owner) -- survivors

    survivors =
      if late_children != [] do
        survivors ++ await_orphans_pids(late_children, min(orphan_timeout, 1_000))
      else
        survivors
      end

    if survivors != [] do
      names = Enum.map(survivors, &format_orphan/1)

      require Logger

      Logger.warning(
        "sandbox_case: #{length(survivors)} orphaned process(es) did not exit " <>
          "within #{orphan_timeout}ms: #{Enum.join(names, ", ")}. " <>
          "The test likely returned before a LiveView or async task finished processing. " <>
          "Add an assert_has for a stable post-event UI element before letting the test return."
      )
    end

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

    Process.delete(:sandbox_case_cleanup)
    :ok
  end

  @doc """
  Mark that cleanup has started. Call before closing browser sessions
  or other teardown that may trigger OwnershipErrors. Errors logged
  after this point are swallowed at checkin.
  """
  def mark_cleanup_started do
    unless Process.get(:sandbox_case_cleanup) do
      Process.put(:sandbox_case_cleanup, System.monotonic_time(:millisecond))
    end
  end

  @doc """
  Wait for orphaned processes to finish naturally (up to timeout).
  Does NOT kill survivors — call `kill_orphans/1` separately.

  Returns a list of pids that did NOT exit within the timeout.

  The timeout can be configured per-test via:

      Process.put(:sandbox_case_orphan_timeout, 15_000)

  Or set in your test module setup:

      setup do
        Process.put(:sandbox_case_orphan_timeout, 15_000)
        :ok
      end
  """
  def await_orphans(owner, timeout \\ @orphan_timeout) do
    children = find_test_children(owner)
    await_orphans_pids(children, timeout)
  end

  # Wait for a specific list of pids to exit. Returns the survivors.
  defp await_orphans_pids(pids, timeout) do
    if pids == [] do
      []
    else
      refs =
        Enum.map(pids, fn pid ->
          {pid, Process.monitor(pid)}
        end)

      deadline = System.monotonic_time(:millisecond) + timeout

      survivors =
        Enum.flat_map(refs, fn {pid, ref} ->
          remaining = max(deadline - System.monotonic_time(:millisecond), 0)

          receive do
            {:DOWN, ^ref, :process, _, _} -> []
          after
            remaining ->
              Process.demonitor(ref, [:flush])
              [pid]
          end
        end)

      survivors
    end
  end

  # Unregistered processes with the test pid in $callers.
  # Registered processes (Cachex locksmith, Ecto pools, etc.) are
  # long-lived system processes that happen to get $callers from
  # test operations — we don't wait for them.
  defp find_test_children(owner) do
    self_pid = self()

    Process.list()
    |> Enum.filter(fn pid ->
      pid != self_pid and pid != owner and
        not registered?(pid) and has_caller?(pid, owner)
    end)
  end

  defp has_caller?(pid, owner) do
    case :erlang.process_info(pid, :dictionary) do
      {:dictionary, dict} ->
        case List.keyfind(dict, :"$callers", 0) do
          {:"$callers", callers} -> owner in callers
          _ -> false
        end

      _ ->
        false
    end
  catch
    _, _ -> false
  end

  defp registered?(pid) do
    case :erlang.process_info(pid, :registered_name) do
      {:registered_name, _} -> true
      _ -> false
    end
  catch
    _, _ -> false
  end

  defp format_orphan(pid) do
    info = :erlang.process_info(pid, [:initial_call, :current_function, :status])

    case info do
      nil ->
        "#{inspect(pid)} (dead)"

      props ->
        init = format_mfa(props[:initial_call])
        current = format_mfa(props[:current_function])
        "#{inspect(pid)} (init: #{init}, current: #{current})"
    end
  catch
    _, _ -> inspect(pid)
  end

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_mfa(nil), do: "?"
  defp format_mfa(other), do: inspect(other)

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
        has_caller =
          case List.keyfind(dict, :"$callers", 0) do
            {:"$callers", callers} -> owner in callers
            _ -> false
          end

        system_supervised =
          case List.keyfind(dict, :"$ancestors", 0) do
            {:"$ancestors", ancestors} -> owner not in ancestors
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
      nil ->
        conn

      metadata ->
        ua = Phoenix.Ecto.SQL.Sandbox.encode_metadata(metadata)
        Plug.Conn.put_req_header(conn, "user-agent", ua)
    end
  end

  @doc """
  Collects all plug modules declared by available adapters.
  Used by the `sandbox_plugs/0` macro at compile time.
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
  Used by the `sandbox_on_mount/0` macro at compile time.
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
      if function_exported?(adapter, :propagate_keys, 1),
        do: adapter.propagate_keys(config),
        else: []
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
