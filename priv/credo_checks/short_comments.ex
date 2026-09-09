defmodule CalCom.Credo.Check.ShortComments do
  @moduledoc """
  Caps a run of `#` comment lines at two.

  A comment earns its place by saying what the code cannot. Two lines is
  enough for that. Past two the block turns into narration — provenance,
  a history of what the code used to do, a paraphrase of the lines below
  it — and it rots the moment the code moves.

  A block is a run of adjacent comment lines, the way the eye reads one:
  a blank line ends it, so a section banner above a paragraph stays two
  blocks. Directive lines (`# sobelow_skip`, `# credo:`, a shebang) carry
  no prose and do not count toward the cap, which leaves the sobelow
  convention its annotation plus two lines of reason.

  `@doc` and `@moduledoc` bodies are strings, not comments, and are out
  of scope — they are the place where a long explanation belongs.

  This file lives under `priv/credo_checks/`, outside the library's
  compile paths — credo is a dev/test dependency, so compiling this
  module into the package would ship the linter with it. Credo loads it
  through `.credo.exs`'s `requires:` list.
  """

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    param_defaults: [max_lines: 2],
    explanations: [
      check: """
      Say it in two lines or put it in the `@doc`.

          # preferred
          # Segment-aware on purpose: a substring match would let a lib
          # path with a `test` directory segment dodge the ban.

          # refused
          # This function renews the session ID and erases the whole
          # session to avoid fixation attacks. If there is any data
          # in the session you may want to preserve after log in/log out,
          # you must explicitly fetch the session data before clearing.
      """,
      params: [max_lines: "The most comment lines one block may hold."]
    ]

  alias Credo.Code
  alias Credo.IssueMeta

  @directive ~r/^#\s*(?:sobelow_skip|credo:|coveralls-ignore)|^#!/

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    max_lines = Params.get(params, :max_lines, __MODULE__)

    source_file
    |> Code.clean_charlists_strings_and_sigils()
    |> Code.to_lines()
    |> Enum.reduce({nil, []}, &tally(&1, &2, max_lines, issue_meta))
    |> close(max_lines, issue_meta)
  end

  # A directive sits inside a block without lengthening it; anything that
  # is not a comment line — a blank one included — closes the block.
  @spec tally(
          {pos_integer(), String.t()},
          {map() | nil, [Credo.Issue.t()]},
          pos_integer(),
          IssueMeta.t()
        ) :: {map() | nil, [Credo.Issue.t()]}
  defp tally({line_no, text}, {run, issues}, max_lines, issue_meta) do
    trimmed = String.trim(text)

    cond do
      directive?(trimmed) -> {run, issues}
      comment?(trimmed) -> {extend(run, line_no), issues}
      true -> {nil, close({run, issues}, max_lines, issue_meta)}
    end
  end

  @spec comment?(String.t()) :: boolean()
  defp comment?(trimmed), do: String.starts_with?(trimmed, "#")

  @spec directive?(String.t()) :: boolean()
  defp directive?(trimmed), do: Regex.match?(@directive, trimmed)

  @spec extend(map() | nil, pos_integer()) :: map()
  defp extend(nil, line_no), do: %{line: line_no, count: 1}
  defp extend(run, _line_no), do: %{run | count: run.count + 1}

  @spec close({map() | nil, [Credo.Issue.t()]}, pos_integer(), IssueMeta.t()) :: [Credo.Issue.t()]
  defp close({nil, issues}, _max_lines, _issue_meta), do: issues

  defp close({run, issues}, max_lines, issue_meta) do
    if run.count > max_lines do
      [issue_for(issue_meta, run, max_lines) | issues]
    else
      issues
    end
  end

  @spec issue_for(IssueMeta.t(), map(), pos_integer()) :: Credo.Issue.t()
  defp issue_for(issue_meta, run, max_lines) do
    format_issue(issue_meta,
      message:
        "this comment runs #{run.count} lines — cut it to #{max_lines}, move it into the @doc, or delete it",
      line_no: run.line
    )
  end
end
