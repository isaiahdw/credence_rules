# credence-file:iosp_mixed_function,repeated_case_arm_body — this module is an
#   AST pattern matcher whose check/2 + Macro.prewalk + build_issue shape is the
#   Rule contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.ForbiddenModuleDependency do
  @moduledoc """
  Architecture rule: config-driven layer enforcement. Declare which
  modules are not allowed to depend on which, and the rule catches
  the violations on a per-file basis.

  LLMs frequently break layering rules because their training corpus
  is full of small examples that smash layers together — controllers
  calling `Repo.*` directly, lib modules reaching into `MyApp.Web`,
  schemas calling contexts (which produces cycles). These are well-
  known bad shapes, but no general-purpose linter knows your project's
  layer rules. This one lets you spell them out.

  ## Configuration

  Edges are configured via `Application` env or rule opts as a list of
  `{source_pattern, target_pattern}` pairs, or three-tuples with an
  `:except` source allowlist:

      config :credence_rules,
        forbidden_edges: [
          # Controllers can't call Repo directly — go through a context.
          {~r/MyAppWeb\\..*Controller$/, ~r/^MyApp\\.Repo$/},

          # Schemas can't call contexts (cycle hazard).
          {~r/MyApp\\..*Schema$/, ~r/^MyApp\\.Context\\./},

          # Lib code can't depend on the web layer.
          {~r/^MyApp\\.Lib\\./, ~r/^MyAppWeb\\./},

          # Only adapters may call HTTP clients. Source regex covers
          # *all* MyApp modules; the `:except` allowlist lets
          # MyApp.Integrations.* keep doing it.
          {~r/^MyApp\\./, ~r/^(Req|HTTPoison|Finch|Tesla|Mint|Hackney)$/,
           except: ~r/^MyApp\\.Integrations\\./},

          # Only the data layer (Repo, contexts) may touch the schema's
          # raw struct — everything else goes through the context API.
          {~r/^MyApp\\./, ~r/^MyApp\\.Repo$/,
           except: ~r/^MyApp\\.(Repo|Accounts|Billing|Devices)/}
        ]

  Patterns can be regex (`~r/.../`) or strings (compiled as regex
  literally — anchor with `^` / `$` as needed). They're matched
  against the fully-qualified module name (`"MyAppWeb.UserController"`).

  The `:except` regex (when present) is matched against the SOURCE
  module. It lets you write rules of the shape *"only these modules
  may depend on X"* without enumerating every other module in the
  project.

  ## Detection

  For each file:

  1. Find the top-level `defmodule X do ... end`. `X` is the source
     module.
  2. For each forbidden edge `{source_re, target_re}` whose
     `source_re` matches `X`, collect every other module name
     referenced inside the file (via `alias`, `import`, `use`,
     `require`, fully-qualified call `Foo.bar(...)`, struct
     `%Foo{}`, type spec `Foo.t()`, etc).
  3. If any referenced module matches `target_re`, emit one finding
     per matching reference.

  References are collected by walking the AST for `{:__aliases__,
  _meta, segments}` nodes — that's the form aliases, calls, structs,
  and specs all share. Nested-module declarations (`defmodule Foo.Bar
  do ... end` inside the outer module) take on the outer module's
  policy for the file.

  Nothing happens when `:forbidden_edges` is empty / unset — the rule
  is opt-in.

  ## Picking a reference source

  Set `:graph_source` per-rule (or via `config :credence_rules,
  graph_source: ...`) to control how dependencies are inferred:

  - `:ast` (default) — walks the file's AST. Catches `alias`,
    `import`, `use`, typespecs, struct refs — anything that
    *mentions* a module. Maximally inclusive; runs anywhere; no
    compile requirement.
  - `:beam` — reads the source module's `:imports` chunk from
    its compiled `.beam`. Only counts real runtime function calls
    — drops alias-only / typespec-only / struct-only references
    that don't generate any code. Requires the project to be
    compiled. Falls back to `:ast` if the BEAM is missing.
  - `:union` — both. AST for inclusivity, BEAM for runtime-truth
    edges AST might miss (macro-emitted calls). AST line numbers
    win on conflicts.

  For boundary enforcement under `--strict`, prefer `:beam` —
  catches the calls that actually execute at runtime without
  flagging the harmless `alias`-without-use cases.

  ## Bad

      # config
      config :credence_rules,
        forbidden_edges: [{~r/Web\\..*Controller$/, ~r/Repo$/}]

      # lib/my_app_web/controllers/user_controller.ex
      defmodule MyAppWeb.UserController do
        use MyAppWeb, :controller

        def index(conn, _) do
          users = MyApp.Repo.all(MyApp.User)
          render(conn, "index.html", users: users)
        end
      end

  Flagged: `MyAppWeb.UserController` (source) references `MyApp.Repo`
  (target) at line 5.

  ## Good

      defmodule MyAppWeb.UserController do
        use MyAppWeb, :controller

        def index(conn, _) do
          users = MyApp.Accounts.list_users()
          render(conn, "index.html", users: users)
        end
      end

  ## Why boundary (not advisory)

  Unlike most rules in the architecture category, this one is
  boundary — `--strict` fails on findings. The justification is
  opt-in: the rule does nothing without an explicit
  `:forbidden_edges` config. If you configured "controllers can't
  call Repo," you presumably want CI to enforce it, not just
  surface a hint. Combined with the baseline gate, you can pin
  existing violations and only fail on new drift.
  """

  use CredenceRules.Rule

  alias CredenceRules.CrossFile.BeamGraph

  @impl true
  def priority, do: 460

  @impl true
  def check(ast, opts) do
    edges = resolve_edges(opts)
    source = source_from(opts)

    case {edges, defining_module(ast)} do
      {[], _} ->
        []

      {_, nil} ->
        []

      {edges, source_module} ->
        applicable_edges =
          Enum.filter(edges, fn {src_re, _, _except} ->
            Regex.match?(src_re, source_module)
          end)

        case applicable_edges do
          [] ->
            []

          edges ->
            ast
            |> collect_references(source_module, source)
            |> Enum.flat_map(fn {ref_module, line} ->
              edges
              |> Enum.flat_map(fn {_src_re, tgt_re, except_re} ->
                cond do
                  ref_module == source_module -> []
                  not Regex.match?(tgt_re, ref_module) -> []
                  # Source-module-side allowlist: when an :except
                  # regex is supplied, the rule doesn't fire on
                  # source modules that match it (e.g. allow
                  # `MyApp.Integrations.*` to keep calling Req).
                  except_re && Regex.match?(except_re, source_module) -> []
                  true -> [build_issue(line, source_module, ref_module)]
                end
              end)
            end)
            |> Enum.uniq_by(fn issue -> {issue.meta.line, issue.meta.target} end)
            |> Enum.sort_by(& &1.meta.line)
        end
    end
  end

  # Default :ast (current behaviour); :beam uses BEAM imports for
  # the source module — drops alias/import/use/typespec references
  # that don't generate runtime calls. Falls back to AST if BEAM
  # is unavailable (module not compiled, beam unreadable).
  defp source_from(opts) do
    case Keyword.get(opts, :graph_source) do
      nil -> Application.get_env(:credence_rules, :graph_source, :ast)
      other -> other
    end
  end

  defp collect_references(ast, _source_module, :ast), do: collect_module_references(ast)

  defp collect_references(ast, source_module, source) when source in [:beam, :union] do
    case BeamGraph.imports_for(source_module) do
      {:ok, modules} ->
        beam_refs = Enum.map(modules, &{&1, nil})

        case source do
          :beam ->
            beam_refs

          :union ->
            ast_refs = collect_module_references(ast)
            ast_keys = ast_refs |> Enum.map(fn {m, _} -> m end) |> MapSet.new()

            # AST refs win for line numbers; BEAM contributes the extra modules.
            ast_refs ++ Enum.reject(beam_refs, fn {m, _} -> MapSet.member?(ast_keys, m) end)
        end

      {:error, _reason} ->
        collect_module_references(ast)
    end
  end

  defp resolve_edges(opts) do
    opts
    |> Keyword.get(
      :forbidden_edges,
      Application.get_env(:credence_rules, :forbidden_edges, [])
    )
    |> Enum.flat_map(&compile_edge/1)
  end

  # Two-tuple and three-tuple edge forms both accepted. The three-
  # tuple form's third element is a keyword list with `:except` for
  # source-module allowlisting:
  #
  #     {~r/^MyApp\./, ~r/^Req$/, except: ~r/^MyApp\.Integrations\./}
  defp compile_edge({src, tgt}), do: compile_edge({src, tgt, []})

  defp compile_edge({src, tgt, opts}) when is_list(opts) do
    except = Keyword.get(opts, :except)

    case {to_regex(src), to_regex(tgt), maybe_to_regex(except)} do
      {%Regex{} = s, %Regex{} = t, e} when is_nil(e) or is_struct(e, Regex) ->
        [{s, t, e}]

      _ ->
        []
    end
  end

  defp compile_edge(_), do: []

  defp to_regex(%Regex{} = r), do: r
  defp to_regex(s) when is_binary(s), do: Regex.compile!(s)
  defp to_regex(_), do: nil

  defp maybe_to_regex(nil), do: nil
  defp maybe_to_regex(value), do: to_regex(value)

  # Find the outermost `defmodule X do ... end` — that's the file's
  # defining module. Sub-modules inherit the outer's policy.
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
  end

  defp module_name(_), do: nil

  defp segment_to_string({:__block__, _, [seg]}) when is_atom(seg), do: Atom.to_string(seg)
  defp segment_to_string(seg) when is_atom(seg), do: Atom.to_string(seg)
  defp segment_to_string(_), do: nil

  # Collect every `__aliases__` reference in the AST with its line.
  # That covers alias / import / use / require / Foo.bar() / %Foo{} /
  # @spec Foo.t() — all of them parse to the same shape.
  defp collect_module_references(ast) do
    {_ast, refs} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, meta, segments} = node, acc when is_list(segments) ->
          case module_name(node) do
            nil -> {node, acc}
            "" -> {node, acc}
            name -> {node, [{name, Keyword.get(meta, :line)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(refs)
  end

  defp build_issue(line, source_module, target_module) do
    %Issue{
      rule: :forbidden_module_dependency,
      message:
        "Forbidden dependency: `#{source_module}` references `#{target_module}`. " <>
          "This pair is configured as a layer-violation in " <>
          "`:forbidden_edges` — move the reference behind a context / boundary " <>
          "module, or update the policy if this is now allowed.",
      meta: %{line: line, source: source_module, target: target_module}
    }
  end
end
