defmodule Trygg.Sleep.Plan do
  @moduledoc """
  A sleep-training plan being followed for a child: "The ABCs of Sleep"
  (`Trygg.Sleep.Abcs`), the Sleep Learning Independence Plan (`Trygg.Sleep.Slip`)
  or a gradual Sleep With Assistance Plan (`Trygg.Sleep.Swap`), as `definition`.
  `started_on` is the local date of the evening of night 1.
  See `Trygg.Sleep.Plans` for starting, stopping and where in the plan tonight is.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @definitions [:abcs, :slip, :swap]
  @statuses [:active, :completed, :stopped]
  @feed_kinds [:nursing, :bottle]

  schema "sleep_plans" do
    field :definition, Ecto.Enum, values: @definitions
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :started_on, :date
    field :ended_on, :date
    # How the night feeds are weaned: nursing or bottle, the feed times (minutes
    # after midnight, evening first) and the amounts they start from (minutes of
    # nursing, or ml).
    field :feed_kind, Ecto.Enum, values: @feed_kinds
    field :feed_times, {:array, :integer}, default: []
    field :feed_amounts, {:array, :integer}, default: []
    # Notes by night number (as a string): "3" => "…".
    field :notes, :map, default: %{}
    # Choices of the plan's method: `"mode"` ("graduated" or "full") for a SLIP,
    # `"variant"` and `"start_minutes"` for a SWAP.
    field :options, :map, default: %{}

    belongs_to :child, Trygg.Families.Child
    belongs_to :started_by, Trygg.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :definition,
      :status,
      :started_on,
      :ended_on,
      :feed_kind,
      :feed_times,
      :feed_amounts,
      :notes,
      :options
    ])
    |> validate_required([:definition, :status, :started_on])
    |> validate_feeds()
    |> validate_options()
    |> unique_constraint(:child_id, name: :sleep_plans_one_active_per_child)
  end

  defp validate_options(changeset) do
    options = get_field(changeset, :options) || %{}

    case get_field(changeset, :definition) do
      :slip ->
        if options["mode"] in ["graduated", "full"],
          do: changeset,
          else: add_error(changeset, :options, "choose graduated or full")

      :swap ->
        cond do
          is_nil(Trygg.Sleep.Swap.variant(options["variant"])) ->
            add_error(changeset, :options, "choose a variant")

          Map.has_key?(options, "start_minutes") and
              not (is_integer(options["start_minutes"]) and options["start_minutes"] in 1..120) ->
            add_error(changeset, :options, "start minutes must be between 1 and 120")

          true ->
            changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_feeds(changeset) do
    times = get_field(changeset, :feed_times) || []
    amounts = get_field(changeset, :feed_amounts) || []

    cond do
      length(times) > 3 ->
        add_error(changeset, :feed_times, "no more than three night feeds")

      length(times) != length(amounts) ->
        add_error(changeset, :feed_amounts, "needs an amount for each feed")

      Enum.any?(times, &(&1 not in 0..1439)) ->
        add_error(changeset, :feed_times, "must be a time of day")

      Enum.any?(amounts, &(&1 < 1)) ->
        add_error(changeset, :feed_amounts, "must be more than zero")

      times != [] and is_nil(get_field(changeset, :feed_kind)) ->
        add_error(changeset, :feed_kind, "choose nursing or bottle")

      true ->
        changeset
    end
  end

  def feed_kinds, do: @feed_kinds
end
