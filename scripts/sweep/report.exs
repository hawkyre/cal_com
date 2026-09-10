defmodule Sweep.Report do
  @moduledoc """
  Writes the two things a sweep leaves behind: one verdict per operation in
  `source/certification.json`, and one redacted capture per operation that
  parsed, in `test/support/fixtures/cal_com/certified/`.

  Both trees are rewritten on every run, so a capture never outlives its
  verdict; a body the contract would not accept goes to `unparsed/` instead,
  marked `"parsed": false`, as the evidence for the fix.
  """

  alias CalCom.{Codec, Response}

  @fixtures "test/support/fixtures/cal_com"

  @doc "Print the summary and write both trees."
  @spec write(map(), map()) :: :ok
  def write(verdicts, account) do
    {captures, verdicts} = split_captures(verdicts)

    IO.puts(
      "\nverdicts: #{inspect(verdicts |> Map.values() |> Enum.frequencies_by(& &1.status))}"
    )

    print_failures(verdicts)
    print_unreachable(verdicts)

    write_source_report(verdicts, account)
    write_captures(captures)
    :ok
  end

  @spec split_captures(map()) :: {[{String.t(), {term(), Response.t()}}], map()}
  defp split_captures(verdicts) do
    Enum.reduce(verdicts, {[], %{}}, fn {id, verdict}, {captures, kept} ->
      case Map.pop(verdict, :capture) do
        {nil, verdict} -> {captures, Map.put(kept, id, verdict)}
        {capture, verdict} -> {[{id, capture} | captures], Map.put(kept, id, verdict)}
      end
    end)
  end

  @spec print_failures(map()) :: :ok
  defp print_failures(verdicts) do
    for status <- ["shape_mismatch", "throttled", "transport", "input"] do
      rows = for {id, verdict} <- Enum.sort(verdicts), verdict.status == status, do: {id, verdict}

      if rows != [] do
        IO.puts("\n#{status} (#{length(rows)}):")

        for {id, verdict} <- rows do
          IO.puts("  #{id} -> #{verdict[:reason]}")

          for {path, why} <- Enum.take(verdict[:fields] || [], 12) do
            IO.puts("      #{path} -> #{String.slice(why, 0, 160)}")
          end
        end
      end
    end

    :ok
  end

  @spec print_unreachable(map()) :: :ok
  defp print_unreachable(verdicts) do
    unreachable =
      for {id, verdict} <- Enum.sort(verdicts), verdict.status == "unreachable", do: {id, verdict}

    probed = Enum.frequencies_by(unreachable, fn {_id, verdict} -> verdict[:probe][:status] end)

    IO.puts(
      "\nunreachable (#{length(unreachable)}), probed with an invented id: #{inspect(probed)}"
    )

    for {id, verdict} <- unreachable do
      probe = verdict[:probe] || %{}

      IO.puts(
        "  #{id} -> #{verdict[:reason]} | probe: #{probe[:status]} #{inspect(probe[:reason])}"
      )
    end

    :ok
  end

  @spec write_source_report(map(), map()) :: :ok
  defp write_source_report(verdicts, account) do
    encoded =
      Map.new(verdicts, fn {id, verdict} ->
        fields =
          for {path, why} <- Map.get(verdict, :fields, []), do: %{"path" => path, "why" => why}

        {id, verdict |> Map.delete(:fields) |> Map.put(:fields, fields)}
      end)

    File.write!(
      "source/certification.json",
      Jason.encode!(
        %{
          "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "account" => account,
          "operations" => encoded
        },
        pretty: true
      ) <> "\n"
    )

    IO.puts("wrote source/certification.json")
    :ok
  end

  @spec write_captures([{String.t(), {term(), Response.t()}}]) :: :ok
  defp write_captures(captures) do
    certified = Path.join(@fixtures, "certified")
    unparsed = Path.join(@fixtures, "unparsed")

    File.rm_rf!(certified)
    File.rm_rf!(unparsed)
    File.mkdir_p!(certified)

    {parsed, rejected} = Enum.split_with(captures, fn {_id, {parsed?, _package}} -> parsed? end)
    for {id, {_parsed, package}} <- parsed, do: write_capture(certified, id, package, true)

    if rejected != [] do
      File.mkdir_p!(unparsed)
      for {id, {_parsed, package}} <- rejected, do: write_capture(unparsed, id, package, false)
    end

    IO.puts("wrote #{length(parsed)} captures to #{certified}")
    if rejected != [], do: IO.puts("wrote #{length(rejected)} unparsed bodies to #{unparsed}")
    :ok
  end

  @doc "Print the counts of one verdict map."
  @spec summary(map()) :: :ok
  def summary(verdicts) do
    # The write pass merges into a report it read back from disk, so some
    # verdicts carry string keys and some atom keys.
    counts =
      verdicts
      |> Map.values()
      |> Enum.frequencies_by(fn verdict -> verdict[:status] || verdict["status"] end)

    IO.puts("verdicts: #{inspect(counts)}")
    :ok
  end

  @doc """
  Write one capture, leaving every other capture alone.

  `parsed: false` is for a body the contract refused: it goes to `unparsed/`,
  where the read pass files one too, so a shape bug keeps its evidence without
  pretending to be a verified response.
  """
  @spec capture!(String.t(), Response.t(), keyword()) :: :ok
  def capture!(id, package, options \\ []) do
    parsed? = Keyword.get(options, :parsed, true)
    dir = Path.join(@fixtures, if(parsed?, do: "certified", else: "unparsed"))

    File.mkdir_p!(dir)
    write_capture(dir, id, package, parsed?)
  end

  @spec write_capture(String.t(), String.t(), Response.t(), boolean()) :: :ok
  defp write_capture(dir, id, package, parsed?) do
    name =
      id
      |> String.replace(" ", "_")
      |> String.replace("/", "-")
      |> String.replace("~", "")
      |> String.replace("{", "")
      |> String.replace("}", "")

    File.write!(
      Path.join(dir, name <> ".json"),
      Jason.encode!(
        %{
          "provider" => "cal_com",
          "operation" => id,
          "http_status" => package.status,
          "captured_on" => Date.utc_today() |> Date.to_iso8601(),
          "parsed" => parsed?,
          "body" => redact(decode(package.body))
        },
        pretty: true
      ) <> "\n"
    )

    :ok
  end

  @spec redact(term()) :: term()
  defp redact(decoded) when is_map(decoded) or is_list(decoded), do: Codec.redact(decoded)
  defp redact(other), do: other

  @spec decode(binary()) :: term()
  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _invalid} -> body
    end
  end
end
