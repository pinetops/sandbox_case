defmodule PhoenixTestOnlyTest do
  use ExUnit.Case, async: true

  describe "test_env?/0" do
    test "returns true when Mix is available and env is :test" do
      assert PhoenixTestOnly.test_env?()
    end
  end
end
