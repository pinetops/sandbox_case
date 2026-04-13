defmodule SandboxCase.RaceConditionTest do
  @moduledoc """
  Tests that verify the checkin order handles race conditions correctly:
  - Orphans with in-flight DB queries
  - Error log attribution
  - Connection pool health after orphan cleanup
  - No log leaks between tests
  """
  use ExUnit.Case, async: false
  # NOT using SandboxCase.Sandbox.Case — these tests manage their own checkout

  alias SandboxCase.TestApp.{Repo, Item}

  describe "checkin ordering" do
    test "orphan doing DB query survives rollback cleanly" do
      sandbox = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: false]])

      {:ok, agent} = Agent.start_link(fn -> nil end)

      Task.start(fn ->
        try do
          Process.sleep(200)
          result = Repo.all(Item)
          Agent.update(agent, fn _ -> {:ok, result} end)
        rescue
          e -> Agent.update(agent, fn _ -> {:error, Exception.message(e)} end)
        end
      end)

      SandboxCase.Sandbox.checkin(sandbox)

      Process.sleep(100)
      result = Agent.get(agent, & &1)
      # Either completed before rollback or got a clean rollback error
      assert result != nil
      Agent.stop(agent)
    end

    test "error from rollback-killed query is captured by logger" do
      sandbox = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: false]])

      Task.start(fn ->
        require Logger

        try do
          Process.sleep(100)
          Repo.all(Item)
        rescue
          e -> Logger.error("Query failed: #{Exception.message(e)}")
        end
      end)

      # fail_on: false means checkin should not raise
      assert :ok = SandboxCase.Sandbox.checkin(sandbox)
    end

    test "connection pool stays healthy after orphan cleanup" do
      sandbox1 = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: false]])

      Task.start(fn ->
        Process.sleep(:infinity)
      end)

      SandboxCase.Sandbox.checkin(sandbox1)

      # New checkout should work — pool isn't corrupted
      sandbox2 = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: false]])
      Repo.insert!(%Item{name: "after-cleanup"})
      assert [%Item{name: "after-cleanup"}] = Repo.all(Item)
      SandboxCase.Sandbox.checkin(sandbox2)
    end

    test "error logs from orphans don't leak to next test" do
      # Test 1: orphan logs an error
      sandbox1 = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: false]])

      Task.start(fn ->
        require Logger
        Process.sleep(50)
        Logger.error("orphan error from test 1")
      end)

      SandboxCase.Sandbox.checkin(sandbox1)

      # Test 2: should NOT see test 1's error
      sandbox2 = SandboxCase.Sandbox.checkout(sandbox: [logger: [fail_on: :error]])

      # If test 1's error leaked, this checkin would raise
      assert :ok = SandboxCase.Sandbox.checkin(sandbox2)
    end
  end

  describe "OwnershipError swallowing during cleanup" do
    test "on_cleanup callback runs before rollback, OwnershipErrors are swallowed" do
      sandbox = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: :error]])

      SandboxCase.Sandbox.on_cleanup(sandbox, fn ->
        require Logger

        Logger.error(
          "Task terminating\n** (DBConnection.OwnershipError) cannot find ownership process"
        )
      end)

      assert :ok = SandboxCase.Sandbox.checkin(sandbox)
    end

    test "owner exited errors during cleanup are swallowed" do
      sandbox = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: :error]])

      SandboxCase.Sandbox.on_cleanup(sandbox, fn ->
        require Logger

        Logger.error(
          "Task terminating\n** (KeyError) key :id not found in: {{:shutdown, \"owner #PID<0.1234.0> exited\"}, {DBConnection.Holder, :checkout, []}}"
        )
      end)

      assert :ok = SandboxCase.Sandbox.checkin(sandbox)
    end

    test "on_cleanup callback runs before await_orphans" do
      sandbox = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: false]])

      {:ok, agent} = Agent.start_link(fn -> false end)

      # Register cleanup that sets a flag
      SandboxCase.Sandbox.on_cleanup(sandbox, fn ->
        Agent.update(agent, fn _ -> true end)
      end)

      SandboxCase.Sandbox.checkin(sandbox)

      # Callback ran
      assert Agent.get(agent, & &1) == true
      Agent.stop(agent)
    end

    test "OwnershipError during cleanup does not fail the test" do
      sandbox = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: :error]])

      Task.start(fn ->
        require Logger
        # Wait for Ecto rollback to happen
        Process.sleep(300)

        # This simulates what happens when a Cachex Courier or start_async
        # task tries DB access after the sandbox is rolled back
        try do
          Repo.all(Item)
        rescue
          e -> Logger.error("OwnershipError: #{Exception.message(e)}")
        end
      end)

      # Checkin rolls back Ecto, which causes the task's query to fail
      # with OwnershipError. This should NOT fail the test because
      # it happened during cleanup.
      assert :ok = SandboxCase.Sandbox.checkin(sandbox)
    end

    test "non-OwnershipError during cleanup still fails" do
      sandbox = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: :error]])

      Task.start(fn ->
        require Logger
        Process.sleep(300)
        Logger.error("something completely different broke")
      end)

      # Non-OwnershipError during cleanup should still fail
      assert_raise RuntimeError, ~r/unconsumed log/, fn ->
        SandboxCase.Sandbox.checkin(sandbox)
      end
    end

    test "OwnershipError during test body is NOT swallowed" do
      sandbox = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: :error]])

      require Logger
      # This happens before checkin — cleanup flag not set yet
      Logger.error("DBConnection.OwnershipError: cannot find ownership process")

      assert_raise RuntimeError, ~r/unconsumed log/, fn ->
        SandboxCase.Sandbox.checkin(sandbox)
      end
    end

    test "real errors during test body are not swallowed" do
      sandbox = SandboxCase.Sandbox.checkout(sandbox: [ecto: true, logger: [fail_on: :error]])

      require Logger
      Logger.error("a real application error")

      # Real errors should fail — OwnershipError filter only applies
      # to that specific error type
      assert_raise RuntimeError, ~r/unconsumed log/, fn ->
        SandboxCase.Sandbox.checkin(sandbox)
      end
    end
  end
end
