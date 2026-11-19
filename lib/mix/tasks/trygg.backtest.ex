defmodule Mix.Tasks.Trygg.Backtest do
  @shortdoc "Scores sleep predictions against a child's own history"

  @moduledoc """
  Replays a child's log through `Trygg.Reports.Backtest` and prints how far off
  the sleep predictions were — the current model next to the one before the
  prediction refinements (`Insights.legacy_features/0`).

      mix trygg.backtest CHILD_ID                 # last 14 days
      mix trygg.backtest CHILD_ID --days 28
      mix trygg.backtest CHILD_ID --half-life 4   # also try a different half-life
      mix trygg.backtest --file export.json       # from a JSON export, no database
      mix trygg.backtest --file export.json --child 3

  Errors are `actual - predicted`; a positive bias means the child sleeps
  later than predicted. Read-only: it writes nothing.

  ## Exporting from a deployed app

  A release has no Mix, so export the last 60 days of entries and run the
  backtest locally. The export is read-only and the file stays on your machine:

      fly ssh console -a trygg -C "/app/bin/trygg rpc 'import Ecto.Query; cs = Trygg.Repo.all(Trygg.Families.Child); es = Trygg.Repo.all(from e in Trygg.Log.Entry, where: e.started_at > ago(60, :day)); IO.puts(Jason.encode!(%{children: Enum.map(cs, &Map.take(&1, [:id, :name, :birth_date, :timezone, :day_start, :night_start, :gestational_age_days])), entries: Enum.map(es, &Map.take(&1, [:id, :child_id, :type, :started_at, :ended_at, :data]))}))'" > export.json

  (The file also contains the `rpc` call's return value after the JSON; the
  importer ignores it.) It holds your children's log, so don't commit it.
  """
  use Mix.Task

  import Ecto.Query

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Backtest
  alias Trygg.Reports.BacktestImport
  alias Trygg.Reports.Insights
  alias Trygg.Repo

  @switches [days: :integer, half_life: :integer, file: :string, child: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: @switches)
    days = opts[:days] || 14
    {child, entries} = load(opts, rest, days)

    variants =
      [current: [], legacy: [features: Insights.legacy_features()]] ++
        if(opts[:half_life],
          do: [{:"half-life #{opts[:half_life]}", [half_life_days: opts[:half_life]]}],
          else: []
        )

    Mix.shell().info("#{child.name}: #{length(entries)} entries, last #{days} days\n")

    for kind <- Backtest.kinds() do
      results = Backtest.compare(child, entries, variants, days: days)
      print(kind, results)
    end
  end

  defp print(kind, results) do
    Mix.shell().info("#{kind}")

    Mix.shell().info(
      "  #{pad("variant", 16)}#{pad("n", 5)}#{pad("MAE", 8)}#{pad("bias", 8)}#{pad("≤15m", 7)}in range"
    )

    for {name, %{kinds: kinds}} <- results do
      s = Map.fetch!(kinds, kind)

      Mix.shell().info(
        "  #{pad(name, 16)}#{pad(s.n, 5)}#{pad(mins(s.mae_seconds), 8)}#{pad(mins(s.bias_seconds), 8)}" <>
          "#{pad(pct(s.within_15_min), 7)}#{pct(s.in_range)}"
      )
    end

    Mix.shell().info("")
  end

  defp mins(nil), do: "–"
  defp mins(seconds), do: "#{if seconds > 0, do: "+"}#{Float.round(seconds / 60, 1)}m"

  defp pct(nil), do: "–"
  defp pct(share), do: "#{round(share * 100)}%"

  defp pad(value, width), do: value |> to_string() |> String.pad_trailing(width)

  defp load(opts, rest, days) do
    if file = opts[:file], do: from_file(file, opts[:child]), else: from_database(rest, days)
  end

  defp from_file(file, child_id) do
    # No database needed: just config, code and the time zone data.
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:tz)

    case file |> File.read!() |> BacktestImport.parse() do
      [] ->
        Mix.raise("#{file} has no children")

      [one] when is_nil(child_id) ->
        one

      many ->
        case Enum.find(many, fn {c, _} -> c.id == child_id end) do
          nil ->
            ids = Enum.map_join(many, ", ", fn {c, _} -> "#{c.id} (#{c.name})" end)
            Mix.raise("pass --child ID, one of: #{ids}")

          found ->
            found
        end
    end
  end

  defp from_database(rest, days) do
    Mix.Task.run("app.start")

    child =
      case rest do
        [id] -> Repo.get(Child, String.to_integer(id)) || Mix.raise("no child with id #{id}")
        _ -> Mix.raise("usage: mix trygg.backtest CHILD_ID | --file export.json [--days N]")
      end

    since = DateTime.add(DateTime.utc_now(), -(days + 20) * 86_400, :second)

    entries =
      Entry
      |> where([e], e.child_id == ^child.id and e.started_at >= ^since)
      |> order_by([e], asc: e.started_at)
      |> Repo.all()

    {child, entries}
  end
end
