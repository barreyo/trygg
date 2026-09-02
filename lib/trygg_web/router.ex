defmodule TryggWeb.Router do
  use TryggWeb, :router

  import TryggWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TryggWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Other scopes may use custom stacks.
  # scope "/api", TryggWeb do
  #   pipe_through :api
  # end

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
    pipe_through [:browser, :require_authenticated_user]

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
