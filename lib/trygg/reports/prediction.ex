defmodule Trygg.Reports.Prediction do
  @moduledoc """
  A single recorded sleep prediction and, once the sleep happens, how far off
  it was.

  One row is opened per `{child, kind, made_from_ts}` — i.e. per wake, per
  `:next_nap` / `:bedtime` — when a prediction is made, and closed out by
  `Trygg.Reports.PredictionLedger` when the child next falls asleep
  (`actual_ts`, signed `error_seconds`) or the predicted sleep never comes
  (`resolved_at` set, `error_seconds` left `nil`).

  Nothing here changes what the app predicts; it is the ground-truth log that
  later tuning of `Trygg.Reports.Insights` and `Trygg.Reports.Norms` is
  measured against.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(next_nap bedtime)a
  @sources ~w(history blended age_prior)a

  schema "sleep_predictions" do
    field :kind, Ecto.Enum, values: @kinds
    field :made_at, :utc_datetime
    field :made_from_ts, :utc_datetime
    field :ordinal, :integer
    field :source, Ecto.Enum, values: @sources
    field :target_ts, :utc_datetime
    field :range_lo_ts, :utc_datetime
    field :range_hi_ts, :utc_datetime
    field :actual_ts, :utc_datetime
    field :error_seconds, :integer
    field :resolved_at, :utc_datetime

    belongs_to :child, Trygg.Families.Child

    timestamps(type: :utc_datetime)
  end

  @doc "The prediction kinds tracked."
  def kinds, do: @kinds

  @doc false
  def changeset(prediction, attrs) do
    prediction
    |> cast(attrs, [
      :child_id,
      :kind,
      :made_at,
      :made_from_ts,
      :ordinal,
      :source,
      :target_ts,
      :range_lo_ts,
      :range_hi_ts,
      :actual_ts,
      :error_seconds,
      :resolved_at
    ])
    |> validate_required([:child_id, :kind, :made_at, :made_from_ts, :source, :target_ts])
  end
end
