defmodule MutagenEx.Test.Compiler do
  @moduledoc """
  Default `MutagenEx.Test.CompilerFacade` implementation — thin wrapper
  over `Code.compile_quoted/2`.

  Tests swap a different module via the `:compiler` config key (preferred)
  or a legacy `{mod, fun}` tuple (back-compat path in
  `MutagenEx.MutationRunner.compiler_module/1`).
  """

  @behaviour MutagenEx.Test.CompilerFacade

  @impl MutagenEx.Test.CompilerFacade
  defdelegate compile_quoted(ast, file), to: Code
end
