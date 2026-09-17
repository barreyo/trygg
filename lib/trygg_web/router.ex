defmodule TryggWeb.Router do
  use TryggWeb, :router

  import Oban.Web.Router
  import TryggWeb.UserAuth

  @secure_browser_headers %{
    "content-security-policy" =>
      "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self' wss: ws:; font-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'",
    "permissions-policy" => "camera=(), microphone=(), geolocation=()",
    "referrer-policy" => "strict-origin-when-cross-origin"
  }

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TryggWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  # Same as :browser, but also accepts "pdf": the reports export route's URL
  # ends in .pdf, which Plug resolves to that format, so it needs its own
  # entry pipeline rather than loosening :accepts for every browser route.
  pipeline :browser_pdf do
    plug :accepts, ["html", "pdf"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TryggWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Other scopes may use custom stacks.
  # scope "/api", TryggWeb do
  #   pipe_through :api
  # end

  # Oban Web dashboard. Open in dev (like LiveDashboard); in production it is
  # behind HTTP Basic Auth and only mounted when OBAN_DASHBOARD_USER /
  # OBAN_DASHBOARD_PASSWORD are set — see `TryggWeb.ObanDashboardAuth`.
  scope "/" do
    pipe_through [:browser, TryggWeb.ObanDashboardAuth]

    oban_dashboard("/oban")
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:trygg, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TryggWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", TryggWeb do
    pipe_through [:browser_pdf, :require_authenticated_user]

    # Plain controller (not a LiveView): streams the Reports tab as a PDF.
    # Same session auth as the LiveViews; the child is membership-scoped.
    get "/c/:id/reports.pdf", ReportPdfController, :show
  end

  scope "/", TryggWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Streams a log entry's attached photo. Membership-scoped like the log itself.
    get "/c/:id/log/:entry_id/photo", PhotoController, :show

    # Web Push subscription registration for the installed PWA. Not a LiveView
    # event: the service-worker/PushManager flow that calls these isn't bound
    # to a live socket.
    post "/push/subscriptions", PushSubscriptionController, :create
    delete "/push/subscriptions", PushSubscriptionController, :delete

    # Batch-sync log entries captured while the PWA was offline. Plain JSON,
    # not a LiveView event: the offline queue is flushed with a bare `fetch`
    # once the device reconnects. Membership-scoped like the log itself.
    post "/c/:id/log/entries", LogSyncController, :create

    live_session :require_authenticated_user,
      on_mount: [
        {TryggWeb.UserAuth, :require_authenticated},
        {TryggWeb.ChildScope, :assign_child}
      ] do
      live "/", DashboardLive, :index
      live "/children", ChildLive.Index, :index
      live "/children/new", ChildLive.Index, :new
      live "/children/:id/edit", ChildLive.Index, :edit

      live "/c/:id", DashboardLive, :show
      live "/c/:id/log", TimelineLive, :index
      live "/c/:id/vitals", VitalsLive, :index
      live "/c/:id/reports", ReportsLive, :index
      live "/c/:id/caregivers", CaregiverLive, :index

      live "/invites/:token", InviteLive, :show
      live "/preferences", PreferencesLive, :edit

      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end
  end

  scope "/", TryggWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{TryggWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
