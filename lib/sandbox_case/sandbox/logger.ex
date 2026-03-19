defmodule SandboxCase.Sandbox.Logger do
  @moduledoc """
  Sandbox adapter that captures logs per test.

  Each test gets its own log buffer via an ETS table. Logs from the
  test process and any process in its `$callers` chain are routed to
  that buffer — no interleaving from concurrent tests.

  ## Configuration

      config :sandbox_case,
        sandbox: [
          logger: true
        ]

  ## Accessing logs

      logs = SandboxCase.Sandbox.Logger.get_logs(context.sandbox_tokens)

      # Each entry is a map: %{level: atom, message: binary, metadata: map}
      assert Enum.any?(logs, & &1.level == :info)
      refute Enum.any?(logs, & &1.level == :error)

  ## Automatic failure on errors

  Pass `fail_on_error: true` to fail the test if any `:error` level
  log is emitted:

      config :sandbox_case,
        sandbox: [
          logger: [fail_on_error: true]
        ]
  """
  @behaviour SandboxCase.Sandbox.Adapter

  @handler_id :sandbox_case_logger
  @table :sandbox_case_log_buffers

  @impl true
  def available?, do: true

  @impl true
  def setup(_config) do
    :ets.new(@table, [:named_table, :public, :bag])
    :logger.add_handler(@handler_id, __MODULE__, %{})
    :ok
  rescue
    ArgumentError -> :ok  # table already exists (re-setup)
  end

  @impl true
  def checkout(config) do
    ref = make_ref()
    Process.put(:sandbox_case_log_ref, ref)
    fail_on_error = config[:fail_on_error] || false
    %{ref: ref, fail_on_error: fail_on_error}
  end

  @impl true
  def checkin(nil), do: :ok

  def checkin(%{ref: ref} = token) do
    Process.delete(:sandbox_case_log_ref)

    if token[:fail_on_error] do
      errors = get_logs_for_ref(ref) |> Enum.filter(& &1.level == :error)

      if errors != [] do
        messages = Enum.map_join(errors, "\n  ", & &1.message)
        raise "Test produced #{length(errors)} error log(s):\n  #{messages}"
      end
    end

    :ets.match_delete(@table, {ref, :_})
    :ok
  end

  @impl true
  def propagate_keys(_config), do: [:sandbox_case_log_ref]

  @doc """
  Get all logs captured during the current test.
  Pass the sandbox_tokens from the test context.
  """
  def get_logs(tokens) when is_list(tokens) do
    case List.keyfind(tokens, __MODULE__, 0) do
      {_, %{ref: ref}} -> get_logs_for_ref(ref)
      _ -> []
    end
  end

  defp get_logs_for_ref(ref) do
    @table
    |> :ets.lookup(ref)
    |> Enum.map(fn {_ref, entry} -> entry end)
  end

  # :logger handler callback
  @doc false
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    case find_log_ref(meta) do
      nil -> :ok
      ref ->
        message = format_message(msg)
        :ets.insert(@table, {ref, %{level: level, message: message, metadata: meta}})
    end
  end

  @doc false
  def adding_handler(config), do: {:ok, config}

  @doc false
  def removing_handler(_config), do: :ok

  # Walk the caller chain to find a process with a log ref.
  defp find_log_ref(meta) do
    pid = Map.get(meta, :pid, self())
    find_log_ref_for_pid(pid)
  end

  defp find_log_ref_for_pid(pid) do
    case process_dict_get(pid, :sandbox_case_log_ref) do
      nil ->
        case process_dict_get(pid, :"$callers") do
          [parent | _] -> find_log_ref_for_pid(parent)
          _ -> nil
        end

      ref ->
        ref
    end
  end

  defp process_dict_get(pid, key) when pid == self() do
    Process.get(key)
  end

  defp process_dict_get(pid, key) do
    case :erlang.process_info(pid, :dictionary) do
      {:dictionary, dict} ->
        case List.keyfind(dict, key, 0) do
          {^key, value} -> value
          _ -> nil
        end

      _ ->
        nil
    end
  catch
    _, _ -> nil
  end

  defp format_message({:string, msg}), do: IO.chardata_to_string(msg)
  defp format_message({:report, report}), do: inspect(report)
  defp format_message(msg) when is_binary(msg), do: msg
  defp format_message(msg), do: inspect(msg)
end
