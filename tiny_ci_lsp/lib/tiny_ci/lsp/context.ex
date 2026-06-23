defmodule TinyCI.LSP.Context do
  @moduledoc """
  Determines the DSL context at a cursor position by walking the AST — not by
  matching the surrounding text with regexes.

  The buffer is usually syntactically incomplete while the author types, so this
  uses `Code.Fragment.container_cursor_to_quoted/1`, which closes the open
  containers around the cursor and inserts a `{:__cursor__, _, _}` marker. We
  then walk that quoted form to the marker, tracking which directive block
  encloses it.

  The returned context drives `TinyCI.LSP.Completion`:

    * `:top_level`  — file scope (offer `name`, `env`, `stage`, hooks)
    * `:stage_body` — inside `stage do … end` (offer `step`, `env`)
    * `:step_body`  — inside `step do … end` (offer `set`)
    * `:hook_body`  — inside `on_success`/`on_failure do … end` (offer `set`)
    * `:stage_opts` — in a stage's option list (offer stage option keys)
    * `:step_opts`  — in a step's option list (offer step option keys)
    * `:hook_opts`  — in a hook's option list (offer hook option keys)
    * `:condition`  — inside a `when:` value (offer condition primitives)
    * `:unknown`    — the fragment could not be analyzed
  """

  @type t ::
          :top_level
          | :stage_body
          | :step_body
          | :hook_body
          | :stage_opts
          | :step_opts
          | :hook_opts
          | :condition
          | :unknown

  @block_directives [:stage, :step, :on_success, :on_failure]

  @doc """
  Maps a cursor context to the `TinyCI.DSL.Spec` scope a symbol resolves in.

  Completion contexts are finer-grained than Spec scopes (a stage's body and its
  option list are different completion contexts but both resolve symbols in the
  `:stage` scope). Used by hover to look the symbol up under the right scope.
  """
  @spec spec_scope(t()) :: :top_level | :stage | :step | :hook | :condition
  def spec_scope(:stage_body), do: :stage
  def spec_scope(:stage_opts), do: :stage
  def spec_scope(:step_body), do: :step
  def spec_scope(:step_opts), do: :step
  def spec_scope(:hook_body), do: :hook
  def spec_scope(:hook_opts), do: :hook
  def spec_scope(:condition), do: :condition
  def spec_scope(_other), do: :top_level

  @doc """
  Returns the DSL context at the 0-based `line`/`character` position in `text`.
  """
  @spec at(String.t(), non_neg_integer(), non_neg_integer()) :: t()
  def at(text, line, character) do
    text
    |> fragment_until(line, character)
    |> Code.Fragment.container_cursor_to_quoted()
    |> case do
      {:ok, quoted} -> classify(quoted)
      _ -> :unknown
    end
  end

  # The cursor sees only the source up to its position: full lines before it,
  # then the current line truncated at the cursor column.
  defp fragment_until(text, line, character) do
    lines = String.split(text, "\n")
    {before_lines, [current | _]} = Enum.split(lines, line)
    truncated = String.slice(current, 0, character)
    Enum.join(before_lines ++ [truncated], "\n")
  end

  defp classify(quoted) do
    case walk(quoted, :top_level) do
      :none -> :unknown
      context -> context
    end
  end

  # ---------------------------------------------------------------------------
  # AST walk toward the cursor marker
  # ---------------------------------------------------------------------------

  # Reaching the marker: the current enclosing context is the answer.
  defp walk({:__cursor__, _, _}, context), do: context

  # A directive that opens a new context for its options/body.
  defp walk({directive, _, args} = node, context) when directive in @block_directives do
    if contains_cursor?(node) do
      walk_directive(directive, args, context)
    else
      :none
    end
  end

  defp walk({:__block__, _, exprs}, context), do: walk_children(exprs, context)

  defp walk(list, context) when is_list(list), do: walk_children(list, context)

  defp walk({left, right}, context), do: walk_children([left, right], context)

  defp walk({_form, _meta, args}, context) when is_list(args),
    do: walk_children(args, context)

  defp walk(_other, _context), do: :none

  defp walk_children(children, context) do
    Enum.reduce_while(children, :none, fn child, _acc ->
      if contains_cursor?(child) do
        {:halt, walk(child, context)}
      else
        {:cont, :none}
      end
    end)
  end

  # Inside a directive call: decide whether the cursor sits in the do-block, in a
  # `when:` value (a condition), or elsewhere in the options.
  defp walk_directive(directive, args, context) do
    {opts_args, do_body} = split_do(args)

    cond do
      do_body != nil and contains_cursor?(do_body) ->
        walk(do_body, body_context(directive))

      when_value_has_cursor?(opts_args) ->
        :condition

      contains_cursor?(opts_args) ->
        opts_context(directive)

      true ->
        context
    end
  end

  defp split_do(args) do
    case Enum.split_with(args, &do_block_arg?/1) do
      {[do_arg | _], rest} -> {rest, Keyword.get(do_arg, :do)}
      {[], rest} -> {rest, nil}
    end
  end

  defp do_block_arg?(arg) when is_list(arg),
    do: Keyword.keyword?(arg) and Keyword.has_key?(arg, :do)

  defp do_block_arg?(_), do: false

  defp when_value_has_cursor?(opts_args) do
    Enum.any?(opts_args, fn
      list when is_list(list) ->
        Keyword.keyword?(list) and
          case Keyword.fetch(list, :when) do
            {:ok, value} -> contains_cursor?(value)
            :error -> false
          end

      _ ->
        false
    end)
  end

  defp body_context(:stage), do: :stage_body
  defp body_context(:step), do: :step_body
  defp body_context(:on_success), do: :hook_body
  defp body_context(:on_failure), do: :hook_body

  defp opts_context(:stage), do: :stage_opts
  defp opts_context(:step), do: :step_opts
  defp opts_context(:on_success), do: :hook_opts
  defp opts_context(:on_failure), do: :hook_opts

  # ---------------------------------------------------------------------------
  # Cursor presence
  # ---------------------------------------------------------------------------

  defp contains_cursor?({:__cursor__, _, _}), do: true
  defp contains_cursor?({left, right}), do: contains_cursor?(left) or contains_cursor?(right)
  defp contains_cursor?({_form, _meta, args}), do: contains_cursor?(args)
  defp contains_cursor?(list) when is_list(list), do: Enum.any?(list, &contains_cursor?/1)
  defp contains_cursor?(_other), do: false
end
