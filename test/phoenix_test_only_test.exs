defmodule PhoenixTestOnlyTest do
  use ExUnit.Case, async: true

  describe "test_env?/0" do
    test "returns true when Mix is available and env is :test" do
      assert PhoenixTestOnly.test_env?()
    end
  end

  describe "Sandbox" do
    test "setup with no config is a no-op" do
      assert :ok = PhoenixTestOnly.Sandbox.setup(sandbox: [])
    end

    test "checkout/checkin round-trip with no adapters" do
      tokens = PhoenixTestOnly.Sandbox.checkout(sandbox: [])
      assert tokens == []
      assert :ok = PhoenixTestOnly.Sandbox.checkin(tokens)
    end

    test "skips unavailable adapters" do
      tokens = PhoenixTestOnly.Sandbox.checkout(sandbox: [cachex: [:nonexistent]])
      assert tokens == []
    end

    test "ecto_metadata returns nil when no ecto token" do
      assert PhoenixTestOnly.Sandbox.ecto_metadata([]) == nil
    end
  end
end
