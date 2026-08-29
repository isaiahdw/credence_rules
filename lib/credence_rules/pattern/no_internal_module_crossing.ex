# credence-file:iosp_mixed_function — this module is an AST pattern matcher
#   whose check/2 + Macro.prewalk + build_issue shape is the Rule contract
#   itself, so the structural duplication is inherent to the form rather than a
#   smell
defmodule CredenceRules.Pattern.NoInternalModuleCrossing do
  @moduledoc """
  Architecture rule: a module named `*.Internal.*` is a deliberate
  internal API for its parent context. Callers outside that context
  shouldn't reach in; they should use the context's public API.

  The convention is widely understood: when an author drops modules
  under `MyApp.Accounts.Internal.*`, they're marking those modules
  as the private implementation of `MyApp.Accounts`. Cross-context
  reaches (`MyApp.Devices.Sync` calling `MyApp.Accounts.Internal.
  PasswordReset` directly) break encapsulation in a way that the
  internal naming explicitly said not to.

  ## Bad

      defmodule MyApp.Devices.Sync do
        alias MyApp.Accounts.Internal.PasswordReset

        def sync(user) do
          # Reaching into another context's Internal namespace.
          PasswordReset.invalidate_all(user)
        end
      end

  ## Good — go through the parent context's public API

      defmodule MyApp.Devices.Sync do
        def sync(user) do
          MyApp.Accounts.invalidate_password_resets(user)
        end
      end

      defmodule MyApp.Accounts do
        defdelegate invalidate_password_resets(user),
          to: MyApp.Accounts.Internal.PasswordReset, as: :invalidate_all
      end

  ## Detection

  For each module reference in the file:

  1. Detect references matching the `:internal_marker_pattern`
     (default `~r/\\.Internal(?:\\.|$)/`).
  2. Compute the **parent context** — the path segment immediately
     before `Internal` (e.g. `MyApp.Accounts.Internal.PasswordReset`
     → context `MyApp.Accounts`).
  3. Flag if the source module's path isn't *under* that parent
     context.

  Same-context references are fine:
  - `MyApp.Accounts` calling `MyApp.Accounts.Internal.Foo` ✓
  - `MyApp.Accounts.Sessions` calling `MyApp.Accounts.Internal.Foo` ✓
  - `MyApp.Accounts.Internal.Foo` calling `MyApp.Accounts.Internal.Bar` ✓

  Cross-context references flag:
  - `MyApp.Devices.Sync` calling `MyApp.Accounts.Internal.Foo` ✗

  ## Configuration

  - `:internal_marker_pattern` — regex matching the Internal-
    namespace shape. Default `~r/\\.Internal(?:\\.|$)/`. Some
    projects use `Private` / `Impl` / `Sub` — override to match
    your convention:

        config :credence_rules,
          rule_opts: %{
            no_internal_module_crossing: [
              internal_marker_pattern: ~r/\\.Private(?:\\.|$)/
            ]
          }

  - `:graph_source` — same shape as `forbidden_module_dependency`.
    `:ast` (default) catches alias/typespec refs too; `:beam` only
    flags runtime calls.

  ## Why boundary

  Crossing an Internal boundary is a clear layering violation — the
  author named the module `Internal` precisely to mark it as
  off-limits. The check is self-opt-in (the rule only fires when
  someone creates an `*.Internal.*` module), so projects that don't
  use this convention pay nothing.
  """

  use CredenceRules.Rule

  alias CredenceRules.CrossFile.BeamGraph

  @default_marker_pattern ~r/\.Internal(?:\.|$)/

  @impl true
  def priority, do: 462

  @impl true
  def check(ast, opts) do
    marker = Keyword.get(opts, :internal_marker_pattern, @default_marker_pattern)
    source = source_from(opts)

    case defining_module(ast) do
      nil ->
        []

      source_module ->
        ast
        |> collect_references(source_module, source)
        |> Enum.flat_map(fn {ref_module, line} ->
          case internal_context(ref_module, marker) do
            nil ->
              []

            context ->
              cond do
                ref_module == source_module -> []
                under_context?(source_module, context) -> []
                true -> [build_issue(line, source_module, ref_module, context)]
              end
          end
        end)
        |> Enum.uniq_by(fn issue -> {issue.meta.line, issue.meta.target} end)
        |> Enum.sort_by(& &1.meta.line)
    end
  end

  # Returns the parent-context segment of an internal-namespace
  # reference, or nil if the reference isn't internal-namespaced.
  # `MyApp.Accounts.Internal.PasswordReset` → `"MyApp.Accounts"`.
  # `MyApp.Internal` (no inner segment) → `"MyApp"`.
  defp internal_context(module_name, marker) do
    case Regex.run(marker, module_name, return: :index) do
      [{start, _len}] when start > 0 -> String.slice(module_name, 0, start)
      _ -> nil
    end
  end

  # The source is "under" the context iff it equals the context or
  # starts with `context.` — same logical bucket, fine to call into
  # the context's Internal namespace.
  defp under_context?(source_module, context) do
    source_module == context or String.starts_with?(source_module, context <> ".")
  end

  # Same graph-source plumbing as forbidden_module_dependency —
  # :ast default, :beam for runtime-truth, :union for both.
  defp source_from(opts) do
    case Keyword.get(opts, :graph_source) do
      nil -> Application.get_env(:credence_rules, :graph_source, :ast)
      other -> other
    end
  end

  defp collect_references(ast, _source_module, :ast), do: collect_alias_references(ast)

  defp collect_references(ast, source_module, source) when source in [:beam, :union] do
    case BeamGraph.imports_for(source_module) do
      {:ok, modules} ->
        beam_refs = Enum.map(modules, &{&1, nil})

        case source do
          :beam ->
            beam_refs

          :union ->
            ast_refs = collect_alias_references(ast)
            ast_keys = ast_refs |> Enum.map(fn {m, _} -> m end) |> MapSet.new()
            ast_refs ++ Enum.reject(beam_refs, fn {m, _} -> MapSet.member?(ast_keys, m) end)
        end

      {:error, _reason} ->
        collect_alias_references(ast)
    end
  end

  defp collect_alias_references(ast) do
    {_ast, refs} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, meta, segments} = node, acc when is_list(segments) ->
          case module_name(node) do
            nil -> {node, acc}
            name -> {node, [{name, Keyword.get(meta, :line)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    refs |> Enum.uniq() |> Enum.sort()
  end

  defp defining_module({:defmodule, _, [alias_node, _body]}), do: module_name(alias_node)

  defp defining_module({:__block__, _, statements}) do
    Enum.find_value(statements, fn
      {:defmodule, _, [alias_node, _body]} -> module_name(alias_node)
      _ -> nil
    end)
  end

  defp defining_module(_), do: nil

  defp module_name({:__aliases__, _, segments}) when is_list(segments) do
    segments
    |> Enum.map(&segment_to_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(".")
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp module_name({:__block__, _, [inner]}), do: module_name(inner)
  defp module_name(_), do: nil

  defp segment_to_string({:__block__, _, [seg]}) when is_atom(seg), do: Atom.to_string(seg)
  defp segment_to_string(seg) when is_atom(seg), do: Atom.to_string(seg)
  defp segment_to_string(_), do: nil

  defp build_issue(line, source_module, ref_module, context) do
    %Issue{
      rule: :no_internal_module_crossing,
      message:
        "`#{source_module}` reaches into `#{ref_module}` — an `Internal` namespace " <>
          "of `#{context}`. The Internal naming marks it as that context's private " <>
          "API. Call through `#{context}`'s public surface instead, or move the " <>
          "shared concept up to a module both contexts can depend on.",
      meta: %{
        line: line,
        source: source_module,
        target: ref_module,
        context: context
      }
    }
  end
end
