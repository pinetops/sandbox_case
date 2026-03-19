defmodule SandboxCase.Sandbox.Redis do
  @moduledoc """
  Sandbox adapter for Redis via Redix.

  Isolates each test by giving it a dedicated Redis database number.
  A pool of Redix connections (each on a different DB) is created at
  setup. On checkout, the test gets a clean connection; on checkin,
  the DB is flushed and returned to the pool.

  ## Configuration

      config :sandbox_case,
        sandbox: [
          redis: [url: "redis://localhost:6379", pool_size: 8]
        ]

  ## Accessing the connection

  In your app code, read the sandboxed connection from the process
  dictionary with a fallback to your default connection:

      def redis_conn do
        Process.get(:redis_sandbox) || MyApp.Redis.default_conn()
      end
  """
  @behaviour SandboxCase.Sandbox.Adapter
  use GenServer

  @impl true
  def available? do
    Code.ensure_loaded?(Redix)
  end

  @impl true
  def setup(config) do
    pool_size = config[:pool_size] || System.schedulers_online()
    url = config[:url] || "redis://localhost:6379"

    conns =
      for db <- 1..pool_size do
        {:ok, conn} = Redix.start_link(url, database: db)
        Redix.command!(conn, ["FLUSHDB"])
        conn
      end

    {:ok, _} = GenServer.start_link(__MODULE__, conns, name: __MODULE__)
    :ok
  end

  @impl true
  def checkout(_config) do
    if Process.whereis(__MODULE__) do
      conn = GenServer.call(__MODULE__, :checkout)
      Redix.command!(conn, ["FLUSHDB"])
      Process.put(:redis_sandbox, conn)
      conn
    end
  end

  @impl true
  def checkin(nil), do: :ok

  def checkin(conn) do
    Process.delete(:redis_sandbox)

    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:checkin, conn})
    end

    :ok
  end

  # -- GenServer pool --

  @impl true
  def init(conns) do
    {:ok, %{available: conns, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:checkout, from, %{available: [], waiting: waiting} = state) do
    {:noreply, %{state | waiting: :queue.in(from, waiting)}}
  end

  def handle_call(:checkout, _from, %{available: [conn | rest]} = state) do
    {:reply, conn, %{state | available: rest}}
  end

  def handle_call({:checkin, conn}, _from, %{available: available, waiting: waiting} = state) do
    case :queue.out(waiting) do
      {{:value, next}, new_waiting} ->
        Redix.command!(conn, ["FLUSHDB"])
        GenServer.reply(next, conn)
        {:reply, :ok, %{state | waiting: new_waiting}}

      {:empty, _} ->
        {:reply, :ok, %{state | available: [conn | available]}}
    end
  end
end
