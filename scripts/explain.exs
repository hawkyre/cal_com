# Turn every stored refusal into machine-readable findings.
#
#   mix run scripts/explain.exs            # prints one line per finding
#   mix run scripts/explain.exs --json     # writes tmp/findings.json
#
# The sweep records the body of every response the contract refused under
# `test/support/fixtures/cal_com/unparsed/`. This re-walks each one against the
# generated types with the *deepest* failure reported, so one run of the sweep
# yields the whole fix list instead of the first field that failed. Each finding
# names the operation, the JSON path, the live value and the contract it broke;
# `scripts/overrides.py` turns findings into `live_overrides.json` patches.
Code.require_file("sweep/client.exs", __DIR__)
Code.require_file("sweep/inputs.exs", __DIR__)
Code.require_file("sweep/judge.exs", __DIR__)

defmodule Explain do
  @moduledoc "Re-walks every unparsed capture into a normalized finding list."

  alias CalCom.Registry
  alias Sweep.Judge

  @unparsed "test/support/fixtures/cal_com/unparsed"

  @doc "Print findings, and write them as JSON when asked."
  @spec main([String.t()]) :: :ok
  def main(argv) do
    findings = findings()

    IO.puts(
      "#{length(findings)} findings across #{length(Enum.uniq_by(findings, & &1["operation"]))} operations"
    )

    for finding <- findings do
      IO.puts("  #{finding["operation"]} #{finding["path"]} :: #{finding["why"]}")
    end

    if "--json" in argv do
      File.mkdir_p!("tmp")
      File.write!("tmp/findings.json", Jason.encode!(findings, pretty: true) <> "\n")
      IO.puts("\nwrote tmp/findings.json")
    end

    :ok
  end

  @doc "One finding per refused field, deepest first."
  @spec findings() :: [map()]
  def findings do
    @unparsed
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(&findings_for/1)
  end

  @spec findings_for(String.t()) :: [map()]
  defp findings_for(path) do
    capture = Jason.decode!(File.read!(path))
    operation = Registry.find(capture["operation"])
    body = capture["body"]

    case operation do
      nil ->
        []

      %{outputs: outputs} ->
        case Enum.find(outputs, &(to_string(&1.status) == to_string(capture["http_status"]))) do
          nil ->
            []

          output ->
            rule = %CalCom.Rule{kind: {:object, output.module}}

            case Judge.fields_for(rule, %{"value" => body}, []) do
              :ok -> []
              {:error, found} -> Enum.map(found, &finding(capture, &1))
            end
        end
    end
  end

  @spec finding(map(), {String.t(), String.t()}) :: map()
  defp finding(capture, {path, why}) do
    %{
      "operation" => capture["operation"],
      "status" => capture["http_status"],
      "path" => path,
      "why" => why,
      "observed" => observed(capture["body"], path),
      "parent" =>
        observed(capture["body"], path |> String.split(".") |> Enum.drop(-1) |> Enum.join("."))
    }
  end

  # The value the provider actually sent at a finding's path, so a patcher can
  # tell "the document's object is missing fields" from "this is the disabled
  # marker the document models as a union other endpoints already carry".
  @spec observed(term(), String.t()) :: term()
  defp observed(body, path) do
    path
    |> String.split(".")
    |> Enum.reject(&(&1 in ["", "value"]))
    |> Enum.reduce(body, fn segment, value ->
      key = Regex.replace(~r/\[\d+\]$/, segment, "")
      index = Regex.run(~r/\[(\d+)\]$/, segment)

      case value do
        %{} = map -> Map.get(map, key)
        [head | _rest] when is_binary(index) -> head
        _other -> nil
      end
    end)
  end
end

Explain.main(System.argv())
