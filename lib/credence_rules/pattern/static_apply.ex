defmodule CredenceRules.Pattern.StaticApply do
  @moduledoc """
  Idiomatic rule: `apply/3` whose module *and* function are compile-time
  literals should be a direct call.

  `apply(Foo.Bar, :baz, [1, 2])` is `Foo.Bar.baz(1, 2)` with extra
  steps. The direct form:

  - is faster (no apply-call overhead, dispatch is resolvable at compile time);
  - lets `mix xref` track the dependency edge;
  - surfaces in `Dialyzer` and the compiler's "undefined function"
    warnings (the apply form bypasses these);
  - reads like Elixir, not like Python's `getattr(module, name)(args)`.

  Reach for `apply/3` only when the module *or* function name is
  genuinely dynamic — a configured adapter, a registry lookup, a fn
  passed in as an argument. When they're literals, you don't need it.

  ## Bad

      apply(MyApp.Worker, :process, [item])

  ## Good

      MyApp.Worker.process(item)

  ## Still-legitimate uses (not flagged)

      apply(adapter_module, :run, [arg])     # module is dynamic
      apply(__MODULE__, fun_name, args)      # function is dynamic
      apply(mod, fun, [a, b] ++ rest)        # args list is dynamic — still flagged if mod+fun are literal
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 320

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:apply, meta, [mod, fun, args]} = node, acc ->
          if literal_module?(mod) and literal_fun?(fun),
            do: {node, [build_issue(meta, mod, fun, args) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # `Foo` / `Foo.Bar` (alias) is literal. `__MODULE__` and bare module
  # atoms like `:erlang` are also literal — flag them too.
  defp literal_module?({:__aliases__, _, parts}) when is_list(parts), do: true
  defp literal_module?({:__MODULE__, _, _}), do: true
  defp literal_module?(mod) when is_atom(mod), do: true
  defp literal_module?(_), do: false

  defp literal_fun?(fun) when is_atom(fun), do: true
  defp literal_fun?(_), do: false

  defp build_issue(meta, mod, fun, args) do
    mod_str = format_module(mod)
    arity = if is_list(args), do: "#{length(args)}", else: "_"

    %Issue{
      rule: :static_apply,
      message:
        "`apply(#{mod_str}, :#{fun}, _)` has compile-time literal module " <>
          "and function — use `#{mod_str}.#{fun}(...)` directly so xref / " <>
          "dialyzer / undefined-function warnings work. (Detected arity: #{arity}.)",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end

  defp format_module({:__aliases__, _, parts}),
    do: Enum.map_join(parts, ".", &Atom.to_string/1)

  defp format_module({:__MODULE__, _, _}), do: "__MODULE__"
  defp format_module(mod) when is_atom(mod), do: inspect(mod)
end
