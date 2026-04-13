defmodule SandboxCase.Sandbox.LockMonitor do
  @moduledoc """
  Background monitor that periodically polls Postgres for blocked queries
  and reports the lock chain.

  Catches lock contention between async tests as it happens, instead of
  waiting for the ownership timeout (15-120s).

  ## Configuration

      config :sandbox_case,
        sandbox: [
          lock_monitor: true
          # or with options:
          lock_monitor: [interval: 2_000, repo: MyApp.Repo]
        ]

  ## What it reports

  When a query is blocked waiting for a lock, the monitor logs:
  - The blocked query and how long it's been waiting
  - The blocking query and its state
  - Both Postgres PIDs for further investigation
  """
  use GenServer

  require Logger

  @default_interval 2_000

  @lock_query """
  SELECT
    blocked_activity.pid AS blocked_pid,
    blocked_activity.query AS blocked_query,
    blocked_activity.wait_event_type AS wait_type,
    blocked_activity.state AS blocked_state,
    extract(epoch from now() - blocked_activity.query_start)::float AS blocked_seconds,
    blocking_activity.pid AS blocking_pid,
    blocking_activity.query AS blocking_query,
    blocking_activity.state AS blocking_state,
    extract(epoch from now() - blocking_activity.query_start)::float AS blocking_seconds
  FROM pg_stat_activity blocked_activity
  JOIN pg_locks blocked_locks ON blocked_locks.pid = blocked_activity.pid
  JOIN pg_locks blocking_locks
    ON blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
    AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
    AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
    AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
    AND blocking_locks.pid != blocked_locks.pid
    AND blocking_locks.granted
  JOIN pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
  WHERE NOT blocked_locks.granted
  """

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    repo = opts[:repo]
    interval = opts[:interval] || @default_interval

    if repo do
      schedule(interval)
      {:ok, %{repo: repo, interval: interval}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:poll, state) do
    check_for_locks(state.repo)
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp check_for_locks(repo) do
    case repo.query(@lock_query, [], log: false, timeout: 5_000) do
      {:ok, %{rows: rows}} when rows != [] ->
        report_locks(rows)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp report_locks(rows) do
    details =
      Enum.map_join(rows, "\n\n", fn row ->
        [
          blocked_pid,
          blocked_query,
          wait_type,
          blocked_state,
          blocked_secs,
          blocking_pid,
          blocking_query,
          blocking_state,
          blocking_secs
        ] = row

        """
          BLOCKED: PG pid #{blocked_pid} (#{blocked_state}, waiting #{format_secs(blocked_secs)}, #{wait_type})
            Query: #{truncate(blocked_query)}
          HELD BY: PG pid #{blocking_pid} (#{blocking_state}, #{format_secs(blocking_secs)})
            Query: #{truncate(blocking_query)}\
        """
      end)

    Logger.warning("""
    SandboxCase LockMonitor: #{length(rows)} blocked query(ies) detected:

    #{details}
    """)
  end

  defp schedule(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp format_secs(nil), do: "?"
  defp format_secs(secs) when is_float(secs), do: "#{Float.round(secs, 1)}s"
  defp format_secs(secs), do: "#{secs}s"

  defp truncate(nil), do: "(none)"
  defp truncate(s) when byte_size(s) > 200, do: String.slice(s, 0..197) <> "..."
  defp truncate(s), do: s
end
