defmodule SandboxCase.TestApp.FlaggedLive do
  use Phoenix.LiveView

  import SandboxCase
  sandbox_on_mount()

  def mount(_params, _session, socket) do
    enabled = FunWithFlags.enabled?(:test_feature)
    {:ok, assign(socket, feature_enabled: enabled)}
  end

  def render(assigns) do
    ~H"""
    <p id="flag">{if @feature_enabled, do: "feature-on", else: "feature-off"}</p>
    """
  end
end
