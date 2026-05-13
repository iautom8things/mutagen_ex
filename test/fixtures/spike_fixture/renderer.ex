defmodule SpikeFixture.Renderer do
  @moduledoc """
  Hand-rolled `__using__/1` registering attributes + callbacks, plus a
  consumer in the same file so a single source-text → quoted →
  recompile round-trip exercises both halves.

  The C1 spike asserts that after a bytecode-restore cycle (cover-stop
  + `Code.compile_quoted/1` of the cached AST):

  - `Module.get_attribute(SpikeFixture.Renderer.HtmlRenderer,
    :spike_renderer_kind)` deltas match a fresh compile baseline (the
    attribute survived the round-trip), and
  - `SpikeFixture.Renderer.HtmlRenderer.__renderer_kind__/0` still
    exists (the injected callback survived).
  """

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :spike_renderer_kind, persist: true)
      @spike_renderer_kind :registered

      @before_compile SpikeFixture.Renderer
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __renderer_kind__, do: @spike_renderer_kind
    end
  end
end

defmodule SpikeFixture.Renderer.HtmlRenderer do
  @moduledoc """
  Consumer of `SpikeFixture.Renderer.__using__/1`. The mutation target
  is `render/1`'s literal — flipping it makes the fixture test fail.
  """

  use SpikeFixture.Renderer

  def render(:html), do: "<html/>"
  def render(:text), do: "plain"
end
