defmodule SandboxCase.Sandbox.DeadlockDetector do
  @moduledoc """
  On-demand Postgres lock chain reporter.

  Attaches to `[:db_connection, :connection_error]` telemetry. When a
  connection checkout fails (typically a timeout), immediately queries
  `pg_stat_activity` and `pg_locks` to show which queries are blocked
  and which are holding the locks.

  Only works with Postgres repos.

  ## Configuration

      config :sandbox_case,
        sandbox: [
          ecto: true,
          deadlock_detector: true
        ]

  Or with an explicit repo:

      deadlock_detector: [repo: MyApp.Repo]
  """

  require Logger

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

  @doc false
  def setup(config) do
    repo = resolve_repo(config)

    if repo do
      :telemetry.attach(
        "sandbox_case_deadlock_detector",
        [:db_connection, :connection_error],
        &__MODULE__.handle_event/4,
        %{repo: repo}
      )
    end

    :ok
  end

  @doc false
  def handle_event([:db_connection, :connection_error], _measurements, _metadata, %{repo: repo}) do
    check_for_locks(repo)
  end

  @doc """
  Query Postgres for blocked queries right now. Can be called manually.
  """
  def check_for_locks(repo) do
    case repo.query(@lock_query, [], log: false, timeout: 5_000) do
      {:ok, %{rows: rows}} when rows != [] ->
        report_locks(rows)

      {:ok, %{rows: []}} ->
        Logger.warning("""
        SandboxCase DeadlockDetector: connection checkout failed but no Postgres locks detected.
        This may be connection pool exhaustion — check your pool_size vs max_cases.
        """)

      {:error, reason} ->
        Logger.warning("SandboxCase DeadlockDetector: failed to query locks: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("SandboxCase DeadlockDetector: #{Exception.message(e)}")
  end

  defp report_locks(rows) do
    details =
      Enum.map_join(rows, "\n\n", fn row ->
        [blocked_pid, blocked_query, wait_type, blocked_state, blocked_secs,
         blocking_pid, blocking_query, blocking_state, blocking_secs] = row

        """
          BLOCKED: PG pid #{blocked_pid} (#{blocked_state}, waiting #{format_secs(blocked_secs)}, #{wait_type})
            Query: #{truncate(blocked_query)}
          HELD BY: PG pid #{blocking_pid} (#{blocking_state}, #{format_secs(blocking_secs)})
            Query: #{truncate(blocking_query)}\
        """
      end)

    Logger.error("""
    SandboxCase DeadlockDetector: #{length(rows)} blocked Postgres query(ies):

    #{details}
    """)
  end

  defp resolve_repo(config) do
    cond do
      is_list(config) && config[:repo] ->
        config[:repo]

      true ->
        otp_app = Application.get_env(:sandbox_case, :otp_app)
        repos = if otp_app, do: Application.get_env(otp_app, :ecto_repos, []), else: []
        List.first(repos)
    end
  end

  defp format_secs(nil), do: "?"
  defp format_secs(secs) when is_float(secs), do: "#{Float.round(secs, 1)}s"
  defp format_secs(secs), do: "#{secs}s"

  defp truncate(nil), do: "(none)"
  defp truncate(s) when byte_size(s) > 200, do: String.slice(s, 0..197) <> "..."
  defp truncate(s), do: s
end
