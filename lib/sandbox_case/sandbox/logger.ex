defmodule SandboxCase.Sandbox.Logger do
  @moduledoc """
  Sandbox adapter that captures logs per test.

  Each test gets its own log buffer via an ETS table. Logs from the
  test process and any process in its `$callers` chain are routed to
  that buffer — no interleaving from concurrent tests.

  ## Configuration

      # Default — fail on unconsumed :error logs
      logger: true

      # Stricter — fail on unconsumed :warning and above
      logger: [fail_on: :warning]

      # Capture only, never fail
      logger: [fail_on: false]

  ## Pop-based assertions

  Reading logs consumes them. At checkin, only unconsumed logs above
  the `fail_on` threshold trigger failure.

      # Pop the next log at a level (returns message string or nil)
      assert pop_log(sandbox, :error) =~ "sync failed"

      # Pop all logs at a level (returns joined string)
      assert logs(sandbox, :warning) =~ "duplicate"

      # Happy path — never read logs, any error fails at checkin
      test "creates user", %{sandbox: sandbox} do
        User.create!(attrs)
        # checkin: no errors → passes
      end
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
    ensure_handler_installed()

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
        get_entries(ref)
        |> Enum.filter(fn entry ->
          Map.get(@level_severity, entry.level, 0) >= threshold
        end)
        |> Enum.reject(&ownership_error_during_cleanup?/1)

      if failing != [] do
        messages = Enum.map_join(failing, "\n  ", &"[#{&1.level}] #{&1.message}")
        :ets.match_delete(@table, {ref, :_})

        raise "Test produced #{length(failing)} unconsumed log(s) at #{fail_on} or above:\n  #{messages}"
      end
    end

    :ets.match_delete(@table, {ref, :_})
    :ok
  end

  @impl true
  def propagate_keys(_config), do: [:sandbox_case_log_ref]

  # --- Public API ---

  @doc """
  Pop the next log entry at or above `level`. Returns the message
  string, or `nil` if no matching entry exists. Consumes the entry.

      assert pop_log(sandbox, :error) =~ "something broke"
      refute pop_log(sandbox, :error)  # no more errors
  """
  def pop_log(sandbox, level \\ :debug)

  def pop_log(%{tokens: tokens}, level), do: pop_log(tokens, level)

  def pop_log(tokens, level) when is_list(tokens) do
    case find_token(tokens) do
      nil -> nil
      ref -> do_pop_log(ref, level)
    end
  end

  @doc """
  Pop all log entries at or above `level`. Returns the messages
  joined with newlines as a string. Consumes the entries.

      assert logs(sandbox, :error) =~ "failed"
      assert logs(sandbox) =~ "some info message"
  """
  def logs(sandbox, level \\ :debug)

  def logs(%{tokens: tokens}, level), do: logs(tokens, level)

  def logs(tokens, level) when is_list(tokens) do
    case find_token(tokens) do
      nil -> ""
      ref -> do_pop_all(ref, level)
    end
  end

  @doc """
  Get all logs without consuming them (non-destructive).
  Returns a list of `%{level: atom, message: binary, metadata: map}`.
  """
  def get_logs(%{tokens: tokens}), do: get_logs(tokens)

  def get_logs(tokens) when is_list(tokens) do
    case find_token(tokens) do
      nil -> []
      ref -> get_entries(ref)
    end
  end

  # --- Private helpers ---

  defp do_pop_log(ref, level) do
    threshold = Map.get(@level_severity, level, 0)

    # Take all entries for this ref, find first match, re-insert the rest
    all = :ets.take(@table, ref)

    {match, rest} =
      Enum.reduce(all, {nil, []}, fn {_ref, entry} = row, {found, acc} ->
        if is_nil(found) and Map.get(@level_severity, entry.level, 0) >= threshold do
          {entry, acc}
        else
          {found, [row | acc]}
        end
      end)

    # Re-insert unconsumed entries
    for row <- rest, do: :ets.insert(@table, row)

    if match, do: "[#{match.level}] #{match.message}"
  end

  defp do_pop_all(ref, level) do
    threshold = Map.get(@level_severity, level, 0)

    all = :ets.take(@table, ref)

    {matching, rest} =
      Enum.split_with(all, fn {_ref, entry} ->
        Map.get(@level_severity, entry.level, 0) >= threshold
      end)

    # Re-insert entries below the threshold
    for row <- rest, do: :ets.insert(@table, row)

    matching
    |> Enum.map(fn {_ref, entry} -> "[#{entry.level}] #{entry.message}" end)
    |> Enum.join("\n")
  end

  defp get_entries(ref) do
    @table
    |> :ets.lookup(ref)
    |> Enum.map(fn {_ref, entry} -> entry end)
  end

  defp find_token(tokens) do
    case List.keyfind(tokens, __MODULE__, 0) do
      {_, %{ref: ref}} -> ref
      _ -> nil
    end
  end

  # --- :logger handler callback ---

  # Must never raise or Erlang removes the handler
  @doc false
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    case find_log_ref(meta) do
      nil ->
        :ok

      ref ->
        message = format_message(msg)
        logged_at = System.monotonic_time(:millisecond)

        :ets.insert(
          @table,
          {ref, %{level: level, message: message, metadata: meta, logged_at: logged_at}}
        )
    end
  catch
    _, _ -> :ok
  end

  @doc false
  def adding_handler(config), do: {:ok, config}

  @doc false
  def removing_handler(_config), do: :ok

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

  # Only swallow OwnershipErrors logged after cleanup started.
  # During the test body, an OwnershipError means broken sandbox wiring.
  defp ownership_error_during_cleanup?(%{message: message, logged_at: logged_at}) do
    cleanup_started = Process.get(:sandbox_case_cleanup)

    cleanup_started != nil and
      logged_at >= cleanup_started and
      (String.contains?(message, "OwnershipError") or
         String.contains?(message, "cannot find ownership process") or
         (String.contains?(message, "owner") and String.contains?(message, "exited")))
  end

  defp ownership_error_during_cleanup?(_), do: false

  defp ensure_handler_installed do
    unless @handler_id in :logger.get_handler_ids() do
      :logger.add_handler(@handler_id, __MODULE__, %{level: :all})
    end
  catch
    _, _ -> :ok
  end

  defp format_message({:string, msg}), do: IO.chardata_to_string(msg)

  defp format_message({:report, report}) do
    # Use Logger's default formatter to produce readable output,
    # matching what appears in the console
    case :logger.format_otp_report(report) do
      formatted when is_list(formatted) -> IO.chardata_to_string(formatted)
      _ -> inspect(report)
    end
  rescue
    _ -> inspect(report)
  end

  defp format_message(msg) when is_binary(msg), do: msg
  defp format_message(msg), do: inspect(msg)
end
