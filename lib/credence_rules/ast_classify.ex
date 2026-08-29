defmodule CredenceRules.AstClassify do
  @moduledoc """
  Shape predicates for the DRY rules. The clustering rules
  (`repeated_subtree_in_function`, `repeated_subtree_in_module`,
  `cross_file_duplicate_block`) hash normalised subtrees and flag the
  collisions — but two collisions can be structurally identical while
  being categorically different things. These predicates let a rule
  ask *what kind of subtree is this* before reporting:

  - `pure_data?/1` — the subtree is a data literal (table row, keyword
    list, tuple spec) with no calls or branching. Duplicated data
    literals are tables and argument lists, not extractable logic;
    the surrounding list / call site is already their natural home.

  - `references_module?/2` — the subtree calls into at least one
    non-stdlib module. Cross-file, a duplicate that touches only
    stdlib (`Enum`, `Map`, `Logger`, `Application`, …) plus
    control-flow and literals is a language idiom — the same way two
    unrelated modules both write `case Map.get(m, k) do nil -> d; v ->
    v end`. There's no shared *project* concept waiting to be named,
    so extracting a helper would be a fake abstraction.

  - `formatting_only?/2` — the subtree is a log / format-message shape
    (`Logger.error("…: \#{inspect(reason)}")`) with no project-module
    call. Two failure branches that both log-and-return share this
    shape while having opposite policies (`{:stop, reason}` vs degrade
    gracefully); a `log_X/3` helper would either fold the differing
    responses together or be too narrow to earn its name. Log lines
    recur across a healthy codebase by design — that's how Elixir
    logs, not a missing helper.

  Both classify the canonical (pre-normalisation) AST, so they see the
  real module names and call forms — `AstNormalize` would have erased
  the literals `pure_data?/1` keys off and kept the module aliases
  `references_module?/2` keys off, but running before normalisation
  keeps the two concerns independent.
  """

  # Atom-form 3-tuples that *build* data rather than *invoke* logic.
  # A subtree composed only of these (plus literals, atoms, variables,
  # and 2-tuples) constructs a value; it never calls a function or
  # branches.
  #
  # `:__block__` is transparent here: Sourceror wraps every literal and
  # list literal in a `{:__block__, meta, [value]}` node to carry
  # trivia, so a data table parsed by Sourceror is a tree of
  # `__block__` wrappers. We recurse through them — a block whose
  # children are all data is data; a block containing a real call still
  # trips the call clause on that call.
  @data_forms [:{}, :%{}, :%, :<<>>, :|, :__aliases__, :__MODULE__, :__block__]

  # Standard-library / OTP module roots. An aliased call whose first
  # segment is one of these is stdlib, not project. Trailing-segment
  # matching isn't used: a custom `MyApp.Enum` is project code, so we
  # only exempt calls rooted at the real stdlib namespace.
  @stdlib_roots [
    :Enum,
    :Stream,
    :Map,
    :MapSet,
    :Keyword,
    :List,
    :Tuple,
    :String,
    :Integer,
    :Float,
    :Atom,
    :Range,
    :Regex,
    :Base,
    :Bitwise,
    :Kernel,
    :IO,
    :Inspect,
    :Path,
    :File,
    :System,
    :Process,
    :Port,
    :Node,
    :Agent,
    :Task,
    :GenServer,
    :Supervisor,
    :DynamicSupervisor,
    :Registry,
    :Application,
    :Logger,
    :Code,
    :Macro,
    :Module,
    :Exception,
    :Access,
    :Function,
    :Protocol,
    :Calendar,
    :Date,
    :Time,
    :DateTime,
    :NaiveDateTime,
    :URI,
    :Version,
    :Jason,
    :JSON,
    :OptionParser,
    :Mix
  ]

  @doc """
  True if the subtree is a pure data literal — built only from
  literals, atoms, variables, and data containers (tuples, lists,
  maps, structs, binaries, keyword pairs), with no function calls,
  operators, or control-flow.

  Verhoeff lookup-table rows (`[0, 1, 2, …]`), TLV tag/type tuples
  (`{{:context, 1}, {:type, :foo}}`), and argument keyword lists
  (`[serial: serial, issuer: dn, …]`) are all pure data. They hash
  alike because the clustering rules normalise away the per-row
  literal values — but the varying values are exactly why each row is
  its own canonical place in a table, not a helper waiting to happen.
  """
  @spec pure_data?(Macro.t()) :: boolean()
  def pure_data?(node), do: not contains_logic?(node)

  defp contains_logic?(node) do
    {_ast, found?} =
      Macro.prewalk(node, false, fn
        _n, true -> {[], true}
        n, false -> {n, logic_node?(n)}
      end)

    found?
  end

  # Unary +/- on a numeric literal is a negative/positive constant
  # (`-5`), i.e. data — not arithmetic. Checked before the general
  # operator clause so signed literals in a table don't read as logic.
  defp logic_node?({op, _meta, [n]}) when op in [:+, :-] and is_number(n), do: false

  # Aliased remote call (`Foo.bar(...)`), local/operator call, or
  # control-flow — anything that isn't a data-construction form is
  # logic.
  defp logic_node?({form, _meta, args}) when is_atom(form) and is_list(args),
    do: form not in @data_forms

  # Dot call: `Foo.bar(...)`, `var.field`, `mod.fun(...)`. Always logic
  # for the data test — a value literal never dispatches.
  defp logic_node?({{:., _meta, _dotted}, _call_meta, _args}), do: true

  defp logic_node?(_other), do: false

  @doc """
  True if the subtree contains at least one call into a non-stdlib
  module — an aliased remote call (`Foo.Bar.baz(...)`) whose root
  segment isn't a standard-library namespace.

  Local calls (`decode(x)`), bare Kernel calls (`inspect(x)`),
  operators, control-flow, and stdlib calls (`Enum.map/2`,
  `Logger.warning/1`) do **not** count — a subtree built only from
  those is a language idiom shared by accident, not a missing shared
  abstraction.

  Pass `:extra_stdlib_modules` (a list of root atoms) to treat
  additional namespaces as stdlib for this check.
  """
  @spec references_module?(Macro.t(), keyword()) :: boolean()
  def references_module?(node, opts \\ []) do
    stdlib = @stdlib_roots ++ Keyword.get(opts, :extra_stdlib_modules, [])

    {_ast, found?} =
      Macro.prewalk(node, false, fn
        _n, true ->
          {[], true}

        {{:., _, [{:__aliases__, _, segs}, fun]}, _, args} = n, false
        when is_atom(fun) and is_list(args) ->
          {n, List.first(segs) not in stdlib}

        n, false ->
          {n, false}
      end)

    found?
  end

  @doc """
  True if the subtree is logging / CLI scaffolding — it contains a
  scaffolding call and makes no call into a project module. Scaffolding
  calls are:

  - `Logger.{debug,info,warning,error,critical,…}`
  - `Mix.shell().{info,error,…}` — CLI output
  - `OptionParser.{parse,parse!,next}` — CLI argument parsing
  - `inspect`, `to_string` (incl. `Integer.to_string(n, 16)`), and the
    `Kernel.to_string` that string interpolation compiles to

  A duplicate that satisfies this is an idiom, not a missing helper:
  the same `Logger.error("…: \#{inspect(reason)}")` or `Mix.shell().info(…)`
  shape recurs across unrelated spots — that's how Elixir logs and how
  Mix tasks print. Factoring it out yields a helper too thin to name.
  The moment the subtree also calls a project module (`Foo.bar(...)`)
  it's real behavior plus scaffolding and is kept.

  Shares `references_module?/2`'s stdlib notion, so `:extra_stdlib_modules`
  applies here too.
  """
  @spec formatting_only?(Macro.t(), keyword()) :: boolean()
  def formatting_only?(node, opts \\ []) do
    has_formatting_call?(node) and not references_module?(node, opts)
  end

  @doc """
  Policy combiner for the within-function / within-module DRY rules: is
  this duplicate cluster non-extractable boilerplate that should be
  dropped rather than reported?

  True when the cluster is a pure data literal (`pure_data?/1`) or a
  logging idiom (`formatting_only?/2`). Each carve-out is on by default
  and re-enabled independently:

  - `flag_pure_data_duplicates: true` keeps data tables
  - `flag_logging_idioms: true` keeps log-message shapes
  """
  @spec boilerplate_duplicate?(Macro.t(), keyword()) :: boolean()
  def boilerplate_duplicate?(node, opts \\ []) do
    (not Keyword.get(opts, :flag_pure_data_duplicates, false) and pure_data?(node)) or
      (not Keyword.get(opts, :flag_logging_idioms, false) and formatting_only?(node, opts))
  end

  defp has_formatting_call?(node) do
    {_ast, found?} =
      Macro.prewalk(node, false, fn
        _n, true -> {[], true}
        n, false -> {n, formatting_call?(n)}
      end)

    found?
  end

  # `inspect` / `to_string` in any call position — bare (`inspect(x)`),
  # qualified (`Kernel.inspect/1`, `Integer.to_string(n, 16)`), or the
  # `Kernel.to_string` that string interpolation (`"…\#{x}…"`) compiles
  # to.
  defp formatting_call?({{:., _, [_recv, fun]}, _, _}) when fun in [:inspect, :to_string],
    do: true

  defp formatting_call?({fun, _meta, args}) when fun in [:inspect, :to_string] and is_list(args),
    do: true

  # `Mix.shell().info(...)` / `.error(...)` / `.yes?(...)` — CLI output
  # scaffolding, not behavior.
  defp formatting_call?({{:., _, [{{:., _, [{:__aliases__, _, [:Mix]}, :shell]}, _, _}, _fun]}, _, _}),
    do: true

  # `Logger.*` (any function) and `OptionParser.parse/parse!` — logging
  # and CLI argument scaffolding.
  defp formatting_call?({{:., _, [{:__aliases__, _, segs}, fun]}, _, _}) when is_list(segs) do
    case List.first(segs) do
      :Logger -> true
      :OptionParser -> fun in [:parse, :parse!, :next]
      _ -> false
    end
  end

  defp formatting_call?(_other), do: false
end
