defmodule SandboxCase.IntegrationTest do
  use ExUnit.Case, async: true
  use SandboxCase.Sandbox.Case
  use Mimic

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SandboxCase.TestApp.Endpoint

  alias SandboxCase.TestApp.{Repo, Item}

  describe "Ecto sandbox" do
    test "LiveView sees test data", %{sandbox_tokens: tokens} do
      Repo.insert!(%Item{name: "test-item"})

      conn = build_conn_with_sandbox(tokens)
      {:ok, view, _html} = live(conn, "/items")

      assert render(view) =~ "test-item"
    end

    test "data doesn't leak between tests", %{sandbox_tokens: tokens} do
      # No items inserted — previous test's data should not be visible
      conn = build_conn_with_sandbox(tokens)
      {:ok, view, _html} = live(conn, "/items")

      refute render(view) =~ "test-item"
    end
  end

  describe "Mimic stubs" do
    test "stub propagates to LiveView", %{sandbox_tokens: tokens} do
      Mimic.stub(SandboxCase.TestApp.ExternalService, :greeting, fn ->
        "Hello from test"
      end)

      conn = build_conn_with_sandbox(tokens)
      {:ok, view, _html} = live(conn, "/greeting")

      assert render(view) =~ "Hello from test"
    end
  end

  describe "Mox stubs" do
    setup do
      Mox.set_mox_from_context(%{async: true})
      :ok
    end

    test "stub propagates to LiveView", %{sandbox_tokens: tokens} do
      Mox.stub(SandboxCase.TestApp.MockWeather, :temperature, fn -> "72°F" end)

      conn = build_conn_with_sandbox(tokens)
      {:ok, view, _html} = live(conn, "/weather")

      assert render(view) =~ "72°F"
    end
  end

  describe "Cachex sandbox" do
    test "isolated cache with DB fallback", %{sandbox_tokens: tokens} do
      Repo.insert!(%Item{name: "cached-item"})

      conn = build_conn_with_sandbox(tokens)
      {:ok, view, _html} = live(conn, "/cached")

      assert render(view) =~ "cached-item"
    end

    test "cache doesn't leak between tests", %{sandbox_tokens: tokens} do
      Repo.insert!(%Item{name: "other-item"})

      conn = build_conn_with_sandbox(tokens)
      {:ok, view, _html} = live(conn, "/cached")

      assert render(view) =~ "other-item"
      refute render(view) =~ ">cached-item<"
    end
  end

  describe "FunWithFlags sandbox" do
    test "flag enabled in test is visible to LiveView", %{sandbox_tokens: tokens} do
      FunWithFlags.enable(:test_feature)

      conn = build_conn_with_sandbox(tokens)
      {:ok, view, _html} = live(conn, "/flagged")

      assert render(view) =~ "feature-on"
    end

    test "flags don't leak between tests", %{sandbox_tokens: tokens} do
      # :test_feature was enabled in the previous test but shouldn't be here
      conn = build_conn_with_sandbox(tokens)
      {:ok, view, _html} = live(conn, "/flagged")

      assert render(view) =~ "feature-off"
    end
  end

  describe "Logger sandbox" do
    test "captures logs from test process only", %{sandbox_tokens: tokens} do
      require Logger
      Logger.info("hello from this test")

      logs = SandboxCase.Sandbox.Logger.get_logs(tokens)
      assert Enum.any?(logs, &(&1.message =~ "hello from this test"))
    end

    test "logs don't leak between tests", %{sandbox_tokens: tokens} do
      require Logger
      Logger.info("different test")

      logs = SandboxCase.Sandbox.Logger.get_logs(tokens)
      refute Enum.any?(logs, &(&1.message =~ "hello from this test"))
      assert Enum.any?(logs, &(&1.message =~ "different test"))
    end

    test "captures logs from spawned processes", %{sandbox_tokens: tokens} do
      require Logger

      task = Task.async(fn -> Logger.warning("from child") end)
      Task.await(task)

      logs = SandboxCase.Sandbox.Logger.get_logs(tokens)
      assert Enum.any?(logs, &(&1.message =~ "from child"))
    end
  end

  # Build a conn with sandbox metadata encoded in the user-agent,
  # mimicking what a browser testing framework does.
  defp build_conn_with_sandbox(tokens) do
    case SandboxCase.Sandbox.ecto_metadata(tokens) do
      nil ->
        build_conn()

      metadata ->
        ua = Phoenix.Ecto.SQL.Sandbox.encode_metadata(metadata)

        build_conn()
        |> Plug.Conn.put_req_header("user-agent", ua)
    end
  end
end
