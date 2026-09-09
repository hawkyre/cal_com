defmodule CalCom.Credo.Check.PublicFunctionDoc do
  @moduledoc """
  Requires a `@doc` on every public function and macro.

  A public function is a contract; the `@doc` states it where the next
  caller reads it. Three shapes satisfy the check: a `@doc` (including
  an explicit `@doc false`), a preceding `@impl` (callback docs live on
  the behaviour), or an earlier documented clause of the same name and
  arity.

  `test/**` is exempt — helpers there serve one file, matching the
  looser test-boundary discipline of the other custom checks.

  This file lives under `priv/credo_checks/`, outside the library's compile
  paths — credo is a dev/test dependency, so compiling this module into the
  package would ship the linter with it. Credo loads it through
  `.credo.exs`'s `requires:` list.
  """

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      Every public function or macro carries a @doc.

          # preferred
          @doc "Builds the request for one parsed input."
          @spec request(input(), CalCom.Credentials.t()) :: {:ok, CalCom.Request.t()}
          def request(input, credentials), do: ...

          # also fine — callbacks document on the behaviour
          @impl true
          def handle_event(event, params, socket), do: ...

          # refused
          def request(input, credentials), do: ...
      """
    ]

  alias Credo.Code
  alias Credo.IssueMeta

  @message "public functions carry a @doc — state the contract (or @doc false it deliberately)"

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
  # `test` directory segment dodge the check.
  @spec exempt?(String.t()) :: boolean()
  defp exempt?(filename) do
    filename
    |> Path.relative_to_cwd()
    |> Path.split()
    |> List.first()
    |> Kernel.==("test")
  end

  # Each module body is scanned in statement order — @doc and @impl
  # attach to the next definition, so order is the whole game. Nested
  # modules re-enter through the prewalk; defs inside `quote` blocks are
  # not module-body statements and stay out of reach by construction.
  @spec traverse(Macro.t(), [Credo.Issue.t()], IssueMeta.t()) :: {Macro.t(), [Credo.Issue.t()]}
  defp traverse({:defmodule, _meta, [_alias, [do: body]]} = ast, issues, issue_meta) do
    {ast, scan_body(body, issues, issue_meta)}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  @spec scan_body(Macro.t(), [Credo.Issue.t()], IssueMeta.t()) :: [Credo.Issue.t()]
  defp scan_body({:__block__, _meta, statements}, issues, issue_meta) do
    scan_statements(statements, issues, issue_meta)
  end

  defp scan_body(statement, issues, issue_meta) do
    scan_statements([statement], issues, issue_meta)
  end

  @spec scan_statements([Macro.t()], [Credo.Issue.t()], IssueMeta.t()) :: [Credo.Issue.t()]
  defp scan_statements(statements, issues, issue_meta) do
    state = %{doc?: false, impl?: false, documented: MapSet.new(), issues: issues}

    Enum.reduce(statements, state, &scan_statement(&1, &2, issue_meta)).issues
  end

  @spec scan_statement(Macro.t(), map(), IssueMeta.t()) :: map()
  defp scan_statement({:@, _meta, [{:doc, _doc_meta, [_value | _rest]}]}, state, _issue_meta) do
    %{state | doc?: true}
  end

  defp scan_statement({:@, _meta, [{:impl, _impl_meta, [_value]}]}, state, _issue_meta) do
    %{state | impl?: true}
  end

  defp scan_statement({keyword, meta, [head | _rest]}, state, issue_meta)
       when keyword in [:def, :defmacro] do
    case signature(head) do
      nil -> state
      signature -> settle_def(state, signature, meta[:line], issue_meta)
    end
  end

  # A private definition discards any pending @doc (Elixir does too).
  defp scan_statement({keyword, _meta, _args}, state, _issue_meta)
       when keyword in [:defp, :defmacrop] do
    %{state | doc?: false, impl?: false}
  end

  defp scan_statement(_statement, state, _issue_meta), do: state

  @spec settle_def(map(), {atom(), non_neg_integer()}, pos_integer() | nil, IssueMeta.t()) ::
          map()
  defp settle_def(state, signature, line, issue_meta) do
    documented? = state.doc? or state.impl? or MapSet.member?(state.documented, signature)

    state = %{state | doc?: false, impl?: false}

    if documented? do
      %{state | documented: MapSet.put(state.documented, signature)}
    else
      %{state | issues: [issue_for(issue_meta, line) | state.issues]}
    end
  end

  # The name/arity as written: a guarded head unwraps to its call, a
  # bodiless default-header shares the written arity with its clauses.
  @spec signature(Macro.t()) :: {atom(), non_neg_integer()} | nil
  defp signature({:when, _meta, [head | _guards]}), do: signature(head)

  defp signature({name, _meta, args}) when is_atom(name) and is_list(args) do
    {name, length(args)}
  end

  defp signature({name, _meta, nil}) when is_atom(name), do: {name, 0}

  defp signature(_head), do: nil

  @spec issue_for(IssueMeta.t(), pos_integer() | nil) :: Credo.Issue.t()
  defp issue_for(issue_meta, line_no) do
    format_issue(issue_meta, message: @message, line_no: line_no)
  end
end
