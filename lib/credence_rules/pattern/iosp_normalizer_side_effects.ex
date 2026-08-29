# credence-file:cross_file_duplicate_block — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.IospNormalizerSideEffects do
  @moduledoc """
  IOSP rule: a function whose name signals "normalise / parse /
  convert this value" — `normalize_*`, `parse_*`, `to_*`,
  `from_*`, `cast_*`, `serialize_*`, `deserialize_*`, `format_*` —
  should be a **pure transformation** from its arguments to its
  return value. Calling `Repo.*`, an HTTP client, the filesystem,
  or a GenServer from inside breaks the contract: the function
  isn't normalising what was passed in, it's loading more data.

  Companion to `iosp_predicate_side_effects` — same shape
  (function-name convention implies determinism), different name
  set. Predicates return `boolean`, normalizers transform values;
  both should be pure operations the integration layer composes
  with.

  ## Bad

      def parse_token(token) do
        # Hits the database to fetch session — this isn't parsing
        # the token, it's looking it up.
        case Repo.get(Session, token: token) do
          %Session{} = s -> {:ok, s}
          nil -> {:error, :unknown_token}
        end
      end

      def normalize_email(email) do
        # Calls an external API to verify deliverability.
        case Req.get!("https://emails/verify", json: %{email: email}) do
          %{status: 200} -> String.downcase(email)
          _ -> nil
        end
      end

  Each function does I/O disguised as "normalisation." Readers see
  `parse_token(t)` and assume cheap parsing; callers in tight loops
  pay the latency cost.

  ## Good — pure transformation

      def parse_token(token) do
        case Base.url_decode64(token, padding: false) do
          {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
          _ -> {:error, :malformed_token}
        end
      end

      # Lift the lookup to an integration function.
      def fetch_session(raw_token) do
        Repo.get(Session, token: raw_token)
      end

  ## Detection

  Flags any `def` / `defp` whose name matches one of the
  configured normalizer prefixes AND whose body contains a call
  into a configured side-effect module — minus the exemption
  carve-outs below.

  Default normalizer prefixes (configurable via `:normalizer_prefixes`):

  - `normalize_`, `parse_`, `to_`, `from_`, `cast_`, `serialize_`,
    `deserialize_`, `encode_`, `decode_`, `format_`

  Default side-effect modules (configurable via `:side_effect_modules`)
  match `iosp_predicate_side_effects` — Repo / Ecto.Repo, HTTP
  clients (Req, HTTPoison, Finch, Tesla, Mint, Hackney), File,
  System, IO, GenServer, Task, Process, Oban, Phoenix.PubSub.
  Bare-atom Erlang modules (`:ets`, `:dets`, `:mnesia`,
  `:persistent_term`) likewise.

  ## Exemptions

  ### IO precision — pure IO.* functions don't count

  `IO.iodata_to_binary/1`, `IO.iodata_length/1`,
  `IO.chardata_to_string/1`, and everything under `IO.ANSI.*` are
  **pure** (iolist plumbing, ANSI escape strings) despite living
  under the `IO` namespace. A normalizer that builds an iolist
  and flattens it via `IO.iodata_to_binary/1` is doing pure
  binary plumbing, not I/O — don't flag it.

  Override via `:pure_io_functions` opt (atom list of function
  names that count as pure when called as `IO.fun`).

  ### Process introspection (TOCTOU class)

  Same shape as the per-call exemption in
  `iosp_predicate_side_effects` — a normalizer that does
  `Process.info(pid, :registered_name)` to translate a pid into a
  registered name can't be "lifted" without introducing a
  TOCTOU window (the registration can change between the lift
  and the use). Process.alive?/info/whereis,
  :erlang.is_process_alive, and Port.info all skip on a per-call
  basis — the body keeps scanning for OTHER side effects, so a
  normalizer that does `Process.info(...)` AND `Repo.get(...)`
  still fires on the Repo call.

  ### Functions whose name encodes an I/O boundary

  When the function's name explicitly says "I read/write to a
  file or stream" — `parse_file/1`, `decode_from_path/1`,
  `encode_to_io/2`, `read_from_stream/1` — the I/O call is the
  integration contract. The recommended fix ("lift the side
  effect") would push the boundary to every caller, duplicate the
  read, and lose the name's documentation value.

  Recognised suffixes: `_file`, `_from_file`, `_to_file`,
  `_from_path`, `_to_path`, `_from_io`, `_to_io`, `_from_stream`,
  `_to_stream`. Configurable via `:io_boundary_suffixes`.

  ### Mix tasks

  All defs inside `defmodule Mix.Tasks.* do … end` are skipped.
  Mix tasks ARE orchestration + I/O; that's their abstraction.

  ## defguard exemption

  `defguard normalize?(x) when …` (if anyone wrote one) is pure by
  construction. Not flagged — the AST node is `:defguard`, not
  `:def`.

  ## Why advisory

  Some "normalizer-named" functions are intentionally I/O-shaped
  in a domain (`to_struct/1` on a Schema that involves a
  preload, `cast_changeset/2` doing a uniqueness check via
  `Repo.exists?`). Treat findings as "is the I/O intentional, or
  should the loading be lifted out?" — not a hard cap.
  """

  use CredenceRules.Rule

  alias CredenceRules.{AstKeyword, IospExemptions}

  @hint """
  Two-step fix: lift the I/O into an integration function, then
  call the pure normalizer against pre-loaded data.

      # Before — parse + lookup mixed
      def parse_token(token) do
        case Repo.get(Session, token: token) do
          %Session{} = s -> {:ok, s}
          nil -> {:error, :unknown}
        end
      end

      # After — pure parse, lifted lookup
      def parse_token(token) do
        case Base.url_decode64(token, padding: false) do
          {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
          _ -> {:error, :malformed}
        end
      end

      def fetch_session(raw_token) do
        Repo.get(Session, token: raw_token)
      end

  If the function's name explicitly says "I read from a file/io"
  (parse_file/1, encode_to_path/2, decode_from_stream/1), the I/O
  IS the contract — the rule's io_boundary_suffixes carve-out
  auto-skips these.
  """

  @carve_outs [
    "Function names ending in _file / _from_file / _to_file / _from_path / _to_path / _from_io / _to_io / _from_stream / _to_stream — name encodes the I/O boundary. Auto-skipped.",
    "Pure IO.* functions: IO.iodata_to_binary/1, IO.iodata_length/1, IO.chardata_to_string/1, IO.ANSI.* — iolist plumbing / escape strings, no actual I/O. Auto-skipped.",
    "Process.alive?/info/whereis, :erlang.is_process_alive, Port.info — runtime introspection, can't be lifted without TOCTOU. Per-call exemption: walk continues so unrelated side effects (Repo, HTTP, etc.) in the same body still fire.",
    "Inside Mix.Tasks.* modules — orchestration + I/O IS the point. Auto-skipped."
  ]

  @default_normalizer_prefixes ~w(
    normalize_
    parse_
    to_
    from_
    cast_
    serialize_
    deserialize_
    encode_
    decode_
    format_
  )

  @default_side_effect_modules ~w(
    Repo Ecto.Repo
    Req HTTPoison Finch Tesla Mint Hackney
    File System IO
    GenServer Task Process
    Oban
    Phoenix.PubSub
  )

  @default_side_effect_erlang_atoms ~w(ets dets mnesia persistent_term)a

  # Pure `IO.*` functions — iolist plumbing and ANSI helpers that
  # don't actually do I/O. Calls to these don't count as side
  # effects even though IO is in the side-effect module list.
  @default_pure_io_functions ~w(
    iodata_to_binary
    iodata_length
    chardata_to_string
  )a

  # Function-name suffixes that explicitly mark the function as
  # the I/O boundary. The name IS the integration contract; the
  # I/O call is intentional.
  @default_io_boundary_suffixes ~w(
    _file
    _from_file
    _to_file
    _from_path
    _to_path
    _from_io
    _to_io
    _from_stream
    _to_stream
  )

  @impl true
  def priority, do: 461

  @impl true
  def check(ast, opts) do
    prefixes = Keyword.get(opts, :normalizer_prefixes, @default_normalizer_prefixes)
    modules = Keyword.get(opts, :side_effect_modules, @default_side_effect_modules)
    erlang = Keyword.get(opts, :side_effect_erlang_atoms, @default_side_effect_erlang_atoms)
    pure_io_fns = Keyword.get(opts, :pure_io_functions, @default_pure_io_functions)
    io_boundary_suffixes = Keyword.get(opts, :io_boundary_suffixes, @default_io_boundary_suffixes)

    alias_tails =
      modules
      |> Enum.map(&alias_tail/1)
      |> MapSet.new()

    erlang_set = MapSet.new(erlang)
    pure_io_set = MapSet.new(pure_io_fns)

    if IospExemptions.mix_task_module?(ast) do
      # Mix tasks are CLI entry points — orchestration + I/O is
      # their abstraction, not a smell.
      []
    else
      collect_findings(ast, prefixes, alias_tails, erlang_set, pure_io_set, io_boundary_suffixes)
    end
  end

  defp collect_findings(ast, prefixes, alias_tails, erlang_set, pure_io_set, io_boundary_suffixes) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {def_kind, _meta, [head, kw]} = node, acc when def_kind in [:def, :defp] and is_list(kw) ->
          case normalizer_name_and_body(head, kw, prefixes, io_boundary_suffixes) do
            {name, line, body} ->
              # Per-call exemption: `has_side_effect_call?/4` skips
              # Process/Port introspection AND pure-IO calls as it
              # walks. A whole-function `process_introspection?` gate
              # here would hide unrelated Repo/HTTP/File calls in
              # the same body, so the gate is per-call only.
              if has_side_effect_call?(body, alias_tails, erlang_set, pure_io_set),
                do: {node, [build_issue(name, line) | acc]},
                else: {node, acc}

            :no ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp normalizer_name_and_body({:when, _, [inner, _guard]}, kw, prefixes, io_boundary_suffixes),
    do: normalizer_name_and_body(inner, kw, prefixes, io_boundary_suffixes)

  defp normalizer_name_and_body({name, meta, params}, kw, prefixes, io_boundary_suffixes)
       when is_atom(name) and is_list(params) do
    name_str = Atom.to_string(name)

    cond do
      String.ends_with?(name_str, "?") ->
        # Predicate — owned by iosp_predicate_side_effects.
        :no

      io_boundary_named?(name_str, io_boundary_suffixes) ->
        # Function name says "this is the I/O boundary" — skip.
        :no

      Enum.any?(prefixes, &String.starts_with?(name_str, &1)) ->
        body = AstKeyword.get(kw, :do)
        {name, Keyword.get(meta, :line), body}

      true ->
        :no
    end
  end

  defp normalizer_name_and_body({name, meta, nil}, kw, prefixes, io_boundary_suffixes)
       when is_atom(name) do
    normalizer_name_and_body({name, meta, []}, kw, prefixes, io_boundary_suffixes)
  end

  defp normalizer_name_and_body(_, _, _, _), do: :no

  defp io_boundary_named?(name_str, suffixes) do
    Enum.any?(suffixes, &String.ends_with?(name_str, &1))
  end

  defp has_side_effect_call?(nil, _alias_tails, _erlang_set, _pure_io_set), do: false

  defp has_side_effect_call?(body, alias_tails, erlang_set, pure_io_set) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        # Aliased call: e.g. `Repo.insert(...)`, `IO.puts(...)`,
        # `IO.iodata_to_binary(...)`. Multiple skip paths:
        # - Process/Port introspection (per-call, walk continues)
        # - IO.ANSI.* (pure escape-string builders)
        # - pure IO functions (iolist plumbing despite IO namespace)
        # Anything else under the configured side-effect modules
        # short-circuits with true.
        {{:., _, [{:__aliases__, _, segments}, fun]}, _, _} = node, _ ->
          cond do
            IospExemptions.introspection_call?(segments, fun) -> {node, false}
            io_ansi_call?(segments) -> {node, false}
            pure_io_call?(segments, fun, pure_io_set) -> {node, false}
            alias_matches?(segments, alias_tails) -> {node, true}
            true -> {node, false}
          end

        # Bare-atom call: `:ets.lookup(...)`, `:persistent_term.put(...)`.
        # Sourceror wraps bare atoms as `{:__block__, _, [:ets]}` — unwrap.
        # `:erlang.is_process_alive/1` skips here too (per-call, same
        # as the aliased Process.alive? case).
        {{:., _, [erl_atom, fun]}, _, _} = node, _ ->
          cond do
            IospExemptions.introspection_erlang_call?(erl_atom, fun) -> {node, false}
            erlang_atom?(erl_atom, erlang_set) -> {node, true}
            true -> {node, false}
          end

        node, acc ->
          {node, acc}
      end)

    found?
  end

  # `IO.ANSI.*` — all pure (escape-string builders). Match the
  # last two segments without using `Enum.take/2` with a negative
  # argument (which has its own anti-pattern rule).
  defp io_ansi_call?(segs), do: match?([:ANSI, :IO | _], Enum.reverse(segs))

  # `IO.iodata_to_binary` / `IO.iodata_length` / `IO.chardata_to_string`
  # — pure iolist conversion despite the IO namespace. Trailing-
  # segment match so `Kernel.IO` or `MyApp.IO` would also exempt
  # if anyone aliases.
  defp pure_io_call?(segs, fun, pure_io_set) do
    List.last(segs) == :IO and MapSet.member?(pure_io_set, fun)
  end

  defp alias_matches?(segments, alias_tails) do
    Enum.any?(alias_tails, &tail_matches?(segments, &1))
  end

  defp tail_matches?(segments, tail_segments) do
    seg_len = length(segments)
    tail_len = length(tail_segments)

    seg_len >= tail_len and
      Enum.drop(segments, seg_len - tail_len) == tail_segments
  end

  defp erlang_atom?(atom, set) when is_atom(atom), do: MapSet.member?(set, atom)
  defp erlang_atom?({:__block__, _, [atom]}, set) when is_atom(atom), do: MapSet.member?(set, atom)
  defp erlang_atom?(_, _), do: false

  defp alias_tail(name) when is_binary(name) do
    name
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
  end

  defp build_issue(name, line) do
    %Issue{
      rule: :iosp_normalizer_side_effects,
      message:
        "`#{name}` looks like a normalizer (name starts with a transform prefix) " <>
          "but its body calls into a side-effecting module (Repo, HTTP client, " <>
          "GenServer, etc.). Normalizers should be pure transformations from " <>
          "arguments to return value — readers assume `parse_x(t)` is cheap and " <>
          "deterministic. Lift the side effect into an integration function and " <>
          "pass the loaded data to a pure normalizer.",
      meta: %{line: line, function: name}
    }
  end
end
