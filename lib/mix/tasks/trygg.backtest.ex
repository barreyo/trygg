defmodule Mix.Tasks.Trygg.Backtest do
  @shortdoc "Scores sleep predictions against a child's own history"

  @moduledoc """
  Replays a child's log through `Trygg.Reports.Backtest` and prints how far off
  the sleep predictions were — the current model next to the one before the
  prediction refinements (`Insights.legacy_features/0`).

      mix trygg.backtest CHILD_ID                 # last 14 days
      mix trygg.backtest CHILD_ID --days 28
      mix trygg.backtest CHILD_ID --half-life 4   # also try a different half-life

  Errors are `actual - predicted`; a positive bias means the child sleeps
  later than predicted. Read-only: it writes nothing.
  """
  use Mix.Task

  import Ecto.Query

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Backtest
  alias Trygg.Reports.Insights
  alias Trygg.Repo

  @switches [days: :integer, half_life: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _} = OptionParser.parse(args, strict: @switches)

    child =
      case rest do
        [id] -> Repo.get(Child, String.to_integer(id)) || Mix.raise("no child with id #{id}")
        _ -> Mix.raise("usage: mix trygg.backtest CHILD_ID [--days N] [--half-life N]")
      end

    days = opts[:days] || 14
    since = DateTime.add(DateTime.utc_now(), -(days + 20) * 86_400, :second)

    entries =
      Entry
      |> where([e], e.child_id == ^child.id and e.started_at >= ^since)
      |> order_by([e], asc: e.started_at)
      |> Repo.all()

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
end
