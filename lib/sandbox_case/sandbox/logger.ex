defmodule SandboxCase.Sandbox.Logger do
  @moduledoc """
  Sandbox adapter that captures logs per test.

  Each test gets its own log buffer via an ETS table. Logs from the
  test process and any process in its `$callers` chain are routed to
  that buffer — no interleaving from concurrent tests.

  ## Configuration

      # Default — fail on :error logs
      logger: true

      # Stricter — fail on :warning and above
      logger: [fail_on: :warning]

      # Capture only, never fail
      logger: [fail_on: false]

  ## Accessing captured logs

      logs = SandboxCase.Sandbox.Logger.get_logs(context.sandbox)

      # Each entry: %{level: atom, message: binary, metadata: map}
  """
  @behaviour SandboxCase.Sandbox.Adapter

  @handler_id :sandbox_case_logger
  @table :sandbox_case_log_buffers

  @level_severity %{
    debug: 0,
    info: 1,
    notice: 2,
    warning: 3,
    error: 4,
    critical: 5,
    alert: 6,
    emergency: 7
  }

  @impl true
  def available?, do: true

  @impl true
  def setup(_config) do
    :ets.new(@table, [:named_table, :public, :bag])
    :logger.add_handler(@handler_id, __MODULE__, %{level: :all})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def checkout(config) do
    ref = make_ref()
    Process.put(:sandbox_case_log_ref, ref)

    fail_on =
      case config do
        c when is_list(c) -> Keyword.get(c, :fail_on, :error)
        _ -> :error
      end

    %{ref: ref, fail_on: fail_on}
  end

  @impl true
  def checkin(nil), do: :ok

  def checkin(%{ref: ref, fail_on: fail_on}) do
    Process.delete(:sandbox_case_log_ref)

    if fail_on do
      threshold = Map.get(@level_severity, fail_on, 4)

      failing =
        get_logs_for_ref(ref)
        |> Enum.filter(fn entry ->
          Map.get(@level_severity, entry.level, 0) >= threshold
        end)

      if failing != [] do
        messages = Enum.map_join(failing, "\n  ", &"[#{&1.level}] #{&1.message}")
        :ets.match_delete(@table, {ref, :_})
        raise "Test produced #{length(failing)} log(s) at #{fail_on} or above:\n  #{messages}"
      end
    end

    :ets.match_delete(@table, {ref, :_})
    :ok
  end

  @impl true
  def propagate_keys(_config), do: [:sandbox_case_log_ref]

  @doc """
  Get all logs captured during the current test.
  """
  def get_logs(%{tokens: tokens}), do: get_logs(tokens)

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

  # :logger handler callback — must never raise or Erlang removes the handler
  @doc false
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    case find_log_ref(meta) do
      nil -> :ok
      ref ->
        message = format_message(msg)
        :ets.insert(@table, {ref, %{level: level, message: message, metadata: meta}})
    end
  catch
    _, _ -> :ok
  end

  @doc false
  def adding_handler(config), do: {:ok, config}

  @doc false
  def removing_handler(_config), do: :ok

  # The handler runs inline in the calling process, so Process.get works
  # directly. Fall back to walking $callers for child processes.
  defp find_log_ref(_meta) do
    case Process.get(:sandbox_case_log_ref) do
      nil -> find_log_ref_in_callers(Process.get(:"$callers") || [])
      ref -> ref
    end
  end

  defp find_log_ref_in_callers([]), do: nil

  defp find_log_ref_in_callers([pid | rest]) do
    case :erlang.process_info(pid, :dictionary) do
      {:dictionary, dict} ->
        case List.keyfind(dict, :sandbox_case_log_ref, 0) do
          {:sandbox_case_log_ref, ref} -> ref
          _ -> find_log_ref_in_callers(rest)
        end

      _ ->
        find_log_ref_in_callers(rest)
    end
  catch
    _, _ -> find_log_ref_in_callers(rest)
  end

  defp format_message({:string, msg}), do: IO.chardata_to_string(msg)
  defp format_message({:report, report}), do: inspect(report)
  defp format_message(msg) when is_binary(msg), do: msg
  defp format_message(msg), do: inspect(msg)
end
