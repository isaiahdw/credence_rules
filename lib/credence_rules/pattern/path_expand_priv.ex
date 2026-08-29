defmodule CredenceRules.Pattern.PathExpandPriv do
  @moduledoc """
  Release-correctness rule: `Path.expand` applied to a `:code.priv_dir/1`
  result is fragile in releases.

  `:code.priv_dir(:my_app)` already returns an absolute path inside the
  release's `_build/.../lib/<app>/priv` directory. Calling `Path.expand`
  on it (or on a path constructed from it) does one of two things:

  - **In `dev`/`test`** — produces a working path because the cwd is
    the project root and Path.expand resolves relative segments
    correctly.
  - **In a release** — the cwd is whatever the OS process was started
    in (often `/`), so any relative segment in `Path.expand`'s
    second-arg base resolves against the wrong directory. The release
    crashes with `:enoent` only when the code first tries to read
    the file, often deep into startup or on first request.

  The canonical alternative is `Path.join/2`, which does no
  base-relative resolution and produces a literal join:

      # Bad — Path.expand("relative.txt", :code.priv_dir(:my_app))
      # In `dev`: works. In a release: looks under the wrong base.
      Path.expand("schema.json", :code.priv_dir(:my_app))

      # Good — Path.join just concatenates the absolute priv_dir
      # with the relative tail.
      Path.join(:code.priv_dir(:my_app), "schema.json")

  ## Detection

  Flags any `Path.expand/1,2` call whose argument tree contains a
  `:code.priv_dir(_)` call. This catches both:

  - `Path.expand(x, :code.priv_dir(:my_app))` (priv_dir as base)
  - `Path.expand(:code.priv_dir(:my_app) <> "/foo")` (priv_dir in path)

  ## Why this is an LLM-prone pattern

  LLMs reach for `Path.expand` because in many non-release-aware
  languages `expand` is the "canonical absolute path" call. In
  Elixir releases, `:code.priv_dir/1` is already the canonical form;
  expanding it adds nothing and breaks the cwd assumption.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 470

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # Eager form: Path.expand(arg1, arg2)
        {{:., _, [{:__aliases__, _, [:Path]}, :expand]}, meta, args} = node, acc
        when is_list(args) ->
          if contains_priv_dir?(args),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        # Pipe form: lhs |> Path.expand(...) — pipes aren't expanded at
        # AST time, so the priv_dir call lives on the pipe's LHS.
        {:|>, meta, [lhs, rhs]} = node, acc ->
          if path_expand_call?(rhs) and contains_priv_dir?(lhs),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp path_expand_call?({{:., _, [{:__aliases__, _, [:Path]}, :expand]}, _, _}),
    do: true

  defp path_expand_call?(_), do: false

  defp contains_priv_dir?(ast_or_args) do
    {_ast, found?} =
      Macro.prewalk(ast_or_args, false, fn
        _node, true ->
          {[], true}

        {{:., _, [:code, :priv_dir]}, _, _} = node, _ ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp build_issue(meta) do
    %Issue{
      rule: :path_expand_priv,
      message:
        "`Path.expand/_` over a `:code.priv_dir/1` result resolves relative " <>
          "segments against the current working directory — which is the " <>
          "project root in dev but `/` (or wherever the release was started) " <>
          "in production. Use `Path.join(:code.priv_dir(:my_app), \"file\")` " <>
          "for a literal join that works in every environment.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
