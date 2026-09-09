defmodule CalCom.SourceContract do
  @moduledoc "Load fixed generated declarations during compilation only."

  # The contract JSON lives beside the spec at the repository root, not under
  # lib/, so the generator and a reviewer read the same file the compiler does.
  @source_pattern Path.expand("../../source/*_contracts_*.json", __DIR__)

  @doc "Expand a concrete schema declaration from its fixed source file."
  @spec schema(keyword(), Macro.Env.t()) :: {keyword(), String.t() | nil}
  def schema(opts, caller) do
    case load(opts, caller) do
      nil ->
        {opts, nil}

      {contract, path} ->
        fields = Enum.map(contract["fields"], &field/1)

        {[
           fields: fields,
           additional: ast(contract["additional"]),
           additional_type: ast(contract["additional_type"])
         ], path}
    end
  end

  @doc "Expand a concrete operation declaration from its fixed source file."
  @spec operation(keyword(), Macro.Env.t()) :: {keyword(), String.t() | nil}
  def operation(opts, caller) do
    case load(opts, caller) do
      nil ->
        {opts, nil}

      {contract, path} ->
        {[
           input: ast(contract["input"]),
           result: ast(contract["result"]),
           contract: ast(contract["contract"])
         ], path}
    end
  end

  @spec load(keyword(), Macro.Env.t()) :: {map(), String.t()} | nil
  # Compiler macros select a checked-in contract from the fixed path allowlist.
  # Provider data and runtime requests cannot supply a file path to this function.
  defp load(opts, caller) do
    case Keyword.get(opts, :source) do
      nil ->
        nil

      {file, module} ->
        path = Map.fetch!(source_files(), file)

        name =
          module |> Macro.expand(caller) |> Atom.to_string() |> String.trim_leading("Elixir.")

        {path |> File.read!() |> Jason.decode!() |> Map.fetch!(name), path}
    end
  end

  @spec source_files() :: %{String.t() => String.t()}
  defp source_files do
    @source_pattern |> Path.wildcard() |> Map.new(&{Path.basename(&1), &1})
  end

  @spec field(list()) :: Macro.t()
  # Field atoms come from the finite checked-in contracts during macro expansion.
  # Runtime provider values never reach this compiler-only conversion.
  defp field([name, wire, rule, type, required]) do
    {:{}, [], [String.to_atom(name), wire, ast(rule), ast(type), required]}
  end

  @spec ast(String.t()) :: Macro.t()
  defp ast(source), do: Code.string_to_quoted!(source)
end
