defmodule CredenceRules.IospExemptions do
  @moduledoc """
  Shared exemption helpers for the IOSP-family rules
  (`iosp_predicate_side_effects`, `iosp_normalizer_side_effects`,
  `iosp_mixed_function`). Each rule applies the IOSP principle —
  "this function should be pure" — but a few well-defined shapes
  legitimately break that principle without being smells:

  - **Mix tasks** (`Mix.Tasks.*`) are CLI entry points; their
    whole point is orchestration + I/O. Applying IOSP to them is
    the wrong abstraction.
  - **Process introspection** (`Process.alive?/info/whereis`,
    `:erlang.is_process_alive`, `Port.info`) asks the runtime
    "what's true right now?" Lifting the answer creates a TOCTOU
    window.

  ## Per-call vs whole-function exemption

  Two flavours of helper for the introspection case:

  - `introspection_call?/2` and `introspection_erlang_call?/2`
    are **per-call** predicates. Rules use them inside their
    AST walk to skip introspection calls without short-
    circuiting — so a body that composes an introspection call
    with another side effect (e.g. `Process.alive?(pid) and
    Repo.exists?(...)`) still flags the Repo call.
  - `process_introspection?/1` is the legacy **whole-body**
    predicate. Kept for any rule that wants to gate at the
    function level. Prefer the per-call variant for new code —
    whole-function gates are easy to over-extend and silently
    hide unrelated side effects.

  Each helper is conservative: it returns true ONLY when the
  shape is recognised. Unknown shapes don't trip the exemption.
  """

  @doc """
  True if the file's outermost (or first) `defmodule` declares a
  `Mix.Tasks.*` module. Used to skip IOSP rules inside Mix tasks.

  Walks the AST once looking for a `defmodule Mix.Tasks.Foo do …
  end` node. Stops at the first match — Mix-task files usually
  contain exactly one task module, but if the first defmodule is
  `Mix.Tasks.*`, anything that follows is treated as part of the
  task's implementation regardless.
  """
  @spec mix_task_module?(Macro.t()) :: boolean()
  def mix_task_module?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        _node, true ->
          {[], true}

        {:defmodule, _, [alias_node, _body]} = node, _ ->
          if mix_tasks_alias?(alias_node), do: {node, true}, else: {node, false}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp mix_tasks_alias?({:__aliases__, _, [:Mix, :Tasks | _]}), do: true
  defp mix_tasks_alias?({:__block__, _, [inner]}), do: mix_tasks_alias?(inner)
  defp mix_tasks_alias?(_), do: false

  @doc """
  True if the body contains a canonical Process / Port liveness or
  introspection call:

  - `Process.alive?/1`
  - `Process.info/1`, `Process.info/2`
  - `Process.whereis/1`
  - `:erlang.is_process_alive/1`
  - `Port.info/1`, `Port.info/2`

  These ask the runtime for state-as-of-now; lifting the answer to
  a separate integration step creates a TOCTOU window (the process
  can die / get re-registered between the lift and the use). See
  the moduledoc on `iosp_predicate_side_effects` for the
  reasoning.

  Trailing-segment alias matching for `Process` and `Port` so
  custom-aliased namespaces (`MyApp.Process.alive?/1`) also exempt.
  """
  @spec process_introspection?(Macro.t()) :: boolean()
  def process_introspection?(body) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        # Aliased call: dispatch on (module-tail, fun-name) pair.
        # A single clause matches all aliased calls, then we
        # classify in the body — avoids clause-ordering pitfalls
        # where a more-general pattern shadows a more-specific one.
        {{:., _, [{:__aliases__, _, segs}, fun]}, _, _} = node, _ ->
          if introspection_pair?(List.last(segs), fun),
            do: {node, true},
            else: {node, false}

        # :erlang.is_process_alive(pid)
        {{:., _, [:erlang, :is_process_alive]}, _, _} = node, _ ->
          {node, true}

        # Sourceror-wrapped bare-atom :erlang
        {{:., _, [{:__block__, _, [:erlang]}, :is_process_alive]}, _, _} = node, _ ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp introspection_pair?(:Process, fun) when fun in [:alive?, :whereis, :info], do: true
  defp introspection_pair?(:Port, :info), do: true
  defp introspection_pair?(_, _), do: false

  @doc """
  Per-call predicate: true if THIS specific aliased call
  (segments + function name) is a Process / Port introspection
  call. Use when scanning for side effects to skip just the
  introspection call — not to short-circuit the whole walk.

      iex> IospExemptions.introspection_call?([:Process], :alive?)
      true
      iex> IospExemptions.introspection_call?([:MyApp, :Process], :info)
      true
      iex> IospExemptions.introspection_call?([:Process], :send)
      false
      iex> IospExemptions.introspection_call?([:GenServer], :call)
      false
  """
  @spec introspection_call?([atom()], atom()) :: boolean()
  def introspection_call?(segments, fun) when is_list(segments) and is_atom(fun) do
    introspection_pair?(List.last(segments), fun)
  end

  @doc """
  Per-call predicate for bare-atom Erlang calls:
  `:erlang.is_process_alive/1` is the only introspection-shaped
  bare-atom call. Returns true for both the raw atom and the
  Sourceror-wrapped `{:__block__, _, [:erlang]}` variant.

      iex> IospExemptions.introspection_erlang_call?(:erlang, :is_process_alive)
      true
      iex> IospExemptions.introspection_erlang_call?(:erlang, :send)
      false
      iex> IospExemptions.introspection_erlang_call?(:ets, :lookup)
      false
  """
  @spec introspection_erlang_call?(atom() | tuple(), atom()) :: boolean()
  def introspection_erlang_call?(:erlang, :is_process_alive), do: true
  def introspection_erlang_call?({:__block__, _, [:erlang]}, :is_process_alive), do: true
  def introspection_erlang_call?(_, _), do: false
end
