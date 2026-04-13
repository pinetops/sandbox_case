defmodule SandboxCase.LockMonitorTest do
  use ExUnit.Case, async: false

  describe "LockMonitor" do
    test "starts and stops cleanly" do
      {:ok, pid} =
        SandboxCase.Sandbox.LockMonitor.start_link(
          repo: SandboxCase.TestApp.Repo,
          interval: 1_000
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
      refute Process.alive?(pid)
    end

    test "polls without crashing on SQLite" do
      # SQLite doesn't have pg_stat_activity, but the monitor
      # should handle the error gracefully
      {:ok, pid} =
        SandboxCase.Sandbox.LockMonitor.start_link(
          repo: SandboxCase.TestApp.Repo,
          interval: 100
        )

      # Let it poll a couple times
      Process.sleep(250)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "setup starts monitor when configured" do
      SandboxCase.Sandbox.setup(
        sandbox: [
          lock_monitor: [repo: SandboxCase.TestApp.Repo, interval: 60_000]
        ]
      )

      assert Process.whereis(SandboxCase.Sandbox.LockMonitor) != nil
      GenServer.stop(SandboxCase.Sandbox.LockMonitor)
    end
  end
end
