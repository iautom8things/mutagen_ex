defmodule MutagenEx.Test.CompilerFacade do
  @moduledoc """
  Behaviour for the `Code` compile-quoted test seam used by
  `MutagenEx.MutationRunner`.

  Production code calls `Code.compile_quoted/2` to swap mutated AST in
  and out of the loaded module image. The facade exists so tests can
  inject a recording stub (counting calls, raising on specific
  predicates, etc.) without an `apply/3` site at the call point.

  ## Default

  `MutagenEx.Test.Compiler` delegates to `Code.compile_quoted/2`.

  ## Back-compat note

  `MutagenEx.MutationRunner` historically read the compiler seam as
  `Map.get(cfg, :compiler, {Code, :compile_quoted})` — a `{mod, fun}`
  tuple. The runner now accepts both a plain module atom (preferred:
  the module implements this behaviour) and the legacy `{mod, fun}`
  tuple. The legacy shape is honored so existing test stubs that pass
  `{CompilerStub, :compile_quoted}` keep working — see
  `MutagenEx.MutationRunner.compiler_module/1` for the conversion site.
  """

  @doc """
  Compile a quoted AST. Mirrors `Code.compile_quoted/2`.

  Returns the list of `{module, binary}` tuples Code produces; tests may
  return an empty list when bytecode isn't load-bearing for the assertion.
  May raise `CompileError` (or any other exception) to drive the runner's
  compile-error / restore-failure paths.
  """
  @callback compile_quoted(ast :: Macro.t(), file :: binary()) :: [{module(), binary()}]
end
