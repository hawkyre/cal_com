defmodule CalCom.Credo.Check.NoStructBang do
  @moduledoc """
  Bans `struct!/2` everywhere in the package.

  `struct!` raises on an unknown key, so provider-shaped input reaching it
  turns a typed refusal into a crash. Every struct this package builds comes
  from a validated parse or from the generator's fixed declarations, and
  those paths return `{:error, %CalCom.Error{}}` instead. `test/**` is
  exempt: fixtures there compose in-memory structs to assert against.

  This file lives under `priv/credo_checks/`, outside the library's compile
  paths — credo is a dev/test dependency, so compiling this module into the
  package would ship the linter with it. Credo loads it through
  `.credo.exs`'s `requires:` list.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Build every struct through its generated constructor, never `struct!`.

      A generated parse returns `{:ok, struct} | {:error, %CalCom.Error{}}`,
      so an unknown field becomes a typed refusal the caller can branch on.
      `struct!` skips the boundary and raises on the same input.

          # preferred
          {:ok, input} = MyOperation.parse_input(params)

          # refused
          struct!(MyOperation.Input, params)
      """
    ]

  alias Credo.Code
  alias Credo.IssueMeta

  @message "struct! is banned in the package — parse through the generated constructor"

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%Credo.SourceFile{filename: filename} = source_file, params) do
    if exempt?(filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  # Segment-aware on purpose: only files rooted at the top-level test/
  # directory are exempt. A substring match would let a lib path with a
  # `test` directory segment dodge the ban.
  @spec exempt?(String.t()) :: boolean()
  defp exempt?(filename) do
    filename
    |> Path.relative_to_cwd()
    |> Path.split()
    |> List.first()
    |> Kernel.==("test")
  end

  @spec traverse(Macro.t(), [Credo.Issue.t()], IssueMeta.t()) :: {Macro.t(), [Credo.Issue.t()]}
  defp traverse({:struct!, meta, args} = ast, issues, issue_meta) when is_list(args) do
    {ast, [issue_for(issue_meta, meta[:line]) | issues]}
  end

  # The fully-qualified spelling must not slip past the bare-atom match.
  defp traverse(
         {{:., _dot, [{:__aliases__, meta, [:Kernel]}, :struct!]}, _call, args} = ast,
         issues,
         issue_meta
       )
       when is_list(args) do
    {ast, [issue_for(issue_meta, meta[:line]) | issues]}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  @spec issue_for(IssueMeta.t(), pos_integer()) :: Credo.Issue.t()
  defp issue_for(issue_meta, line_no) do
    format_issue(issue_meta, message: @message, line_no: line_no)
  end
end
