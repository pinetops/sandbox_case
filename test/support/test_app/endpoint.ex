defmodule SandboxCase.TestApp.Endpoint do
  use Phoenix.Endpoint, otp_app: :sandbox_case

  @session_options [
    store: :cookie,
    key: "_test_key",
    signing_salt: "test_salt"
  ]

  import SandboxShim
  sandbox_plugs()

  sandbox_socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.Session, @session_options)
  plug(Phoenix.Ecto.CheckRepoStatus, otp_app: :sandbox_case)
  plug(SandboxCase.TestApp.Router)
end
