defmodule SandboxCase.TestApp.WeatherLive do
  use Phoenix.LiveView

  import SandboxShim
  sandbox_on_mount()

  def mount(_params, _session, socket) do
    mock =
      Application.get_env(:sandbox_case, :weather_module, SandboxCase.TestApp.WeatherBehaviour)

    temp = mock.temperature()
    {:ok, assign(socket, temperature: temp)}
  end

  def render(assigns) do
    ~H"""
    <p id="temp">{@temperature}</p>
    """
  end
end
