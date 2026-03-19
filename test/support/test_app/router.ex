defmodule SandboxCase.TestApp.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {SandboxCase.TestApp.Layouts, :root}
  end

  scope "/" do
    pipe_through :browser

    live_session :default do
      live "/items", SandboxCase.TestApp.ItemsLive
      live "/greeting", SandboxCase.TestApp.GreetingLive
      live "/weather", SandboxCase.TestApp.WeatherLive
      live "/cached", SandboxCase.TestApp.CachedLive
      live "/flagged", SandboxCase.TestApp.FlaggedLive
    end
  end
end
