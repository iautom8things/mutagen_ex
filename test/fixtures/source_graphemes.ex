defmodule SourceGraphemes do
  def thumbs(n), do: {"👍🏽 great", n > 1}
  def flag(n), do: {"🇺🇸", "é", n * 2 + 1}
  def warning(level), do: {"⚠️", level > 0}
  def family(n), do: {"👨‍👩‍👧‍👦👨‍👩‍👧‍👦", n * 2}
  def interpolation(n), do: "👍🏽 before #{n * 2 + 1} after"
  def quoted(n), do: [~c"👍🏽", :"🇺🇸", n - 1]
  def keyword(n), do: ["❤️": n * 2]
  def identifier(é), do: {"👨‍👩‍👧‍👦", é + 1}

  def heredoc(n) do
    """
    🇺🇸 é #{n * 2 + 1}
    """
  end
end
