defmodule SandboxCaseTest do
  use ExUnit.Case, async: true

  describe "Sandbox" do
    test "setup with no config is a no-op" do
      assert :ok = SandboxCase.Sandbox.setup(sandbox: [])
    end

    test "checkout/checkin round-trip with no adapters" do
      sandbox = SandboxCase.Sandbox.checkout(sandbox: [])
      assert sandbox.tokens == []
      assert :ok = SandboxCase.Sandbox.checkin(sandbox)
    end

    test "skips unavailable adapters" do
      sandbox = SandboxCase.Sandbox.checkout(sandbox: [redis: [url: "redis://nope"]])
      assert sandbox.tokens == []
    end

    test "ecto_metadata returns nil when no ecto token" do
      assert SandboxCase.Sandbox.ecto_metadata([]) == nil
    end

    test "collect_plugs returns empty list when no adapters configured" do
      prev = Application.get_env(:sandbox_case, :sandbox)
      Application.put_env(:sandbox_case, :sandbox, [])
      assert SandboxCase.Sandbox.collect_plugs() == []

      if prev,
        do: Application.put_env(:sandbox_case, :sandbox, prev),
        else: Application.delete_env(:sandbox_case, :sandbox)
    end

    test "collect_hooks returns empty list when no adapters configured" do
      prev = Application.get_env(:sandbox_case, :sandbox)
      Application.put_env(:sandbox_case, :sandbox, [])
      assert SandboxCase.Sandbox.collect_hooks() == []

      if prev,
        do: Application.put_env(:sandbox_case, :sandbox, prev),
        else: Application.delete_env(:sandbox_case, :sandbox)
    end
  end
end
