# AGENTS.md - Elixir Development Guide

## Project Overview

This is a CLI-only Elixir application. Follow these guidelines to maintain code quality and consistency.

## Code Style & Formatting

### Automatic Formatting
- **Always run `mix format`** before committing code
- Format is configured via `.formatter.exs` in the project root
- Use `mix format --check-formatted` in CI to enforce formatting

### Naming Conventions
- **Modules**: `PascalCase` (e.g., `MyApp.UserService`)
- **Functions**: `snake_case` (e.g., `process_user_data/1`)
- **Variables**: `snake_case` (e.g., `user_name`)
- **Atoms**: `snake_case` (e.g., `:ok`, `:error`, `:user_not_found`)
- **Module attributes**: `snake_case` with `@` prefix (e.g., `@default_timeout`)

## Best Practices

### 1. Pattern Matching Over Conditionals

**DO:**
```elixir
def handle_response({:ok, data}), do: process_data(data)
def handle_response({:error, reason}), do: log_error(reason)

def calculate_discount(%{vip: true, total: total}), do: total * 0.9
def calculate_discount(%{total: total}), do: total
```

**DON'T:**
```elixir
def handle_response(response) do
  if elem(response, 0) == :ok do
    process_data(elem(response, 1))
  else
    log_error(elem(response, 1))
  end
end
```

### 2. Avoid `unless` Statements

**DO:**
```elixir
if valid_input?(input) do
  process(input)
else
  {:error, :invalid_input}
end
```

**DON'T:**
```elixir
unless invalid_input?(input) do
  process(input)
else
  {:error, :invalid_input}
end
```

**Rationale**: `unless` with `else` is confusing and hard to read. Use `if` with positive conditions.

### 3. Use `with` for Complex Happy Paths

**DO:**
```elixir
def create_user(params) do
  with {:ok, validated} <- validate_params(params),
       {:ok, user} <- insert_user(validated),
       {:ok, _email} <- send_welcome_email(user) do
    {:ok, user}
  end
end
```

**DON'T:**
```elixir
def create_user(params) do
  case validate_params(params) do
    {:ok, validated} ->
      case insert_user(validated) do
        {:ok, user} ->
          case send_welcome_email(user) do
            {:ok, _email} -> {:ok, user}
            error -> error
          end
        error -> error
      end
    error -> error
  end
end
```

### 4. Pipe Operator for Data Transformations

**DO:**
```elixir
def process_input(input) do
  input
  |> String.trim()
  |> String.downcase()
  |> String.split(",")
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
end
```

**DON'T:**
```elixir
def process_input(input) do
  trimmed = String.trim(input)
  downcased = String.downcase(trimmed)
  split = String.split(downcased, ",")
  mapped = Enum.map(split, &String.trim/1)
  Enum.reject(mapped, &(&1 == ""))
end
```

### 5. Guard Clauses

**DO:**
```elixir
def divide(_numerator, 0), do: {:error, :division_by_zero}
def divide(numerator, denominator) when is_number(numerator) and is_number(denominator) do
  {:ok, numerator / denominator}
end
def divide(_numerator, _denominator), do: {:error, :invalid_arguments}
```

### 6. Return Tuples for Success/Failure

**DO:**
```elixir
def fetch_user(id) do
  case Repo.get(User, id) do
    nil -> {:error, :not_found}
    user -> {:ok, user}
  end
end
```

**DON'T:**
```elixir
def fetch_user(id) do
  Repo.get(User, id) || raise "User not found"
end
```

### 7. Use Bang Functions Appropriately

- Use `!` suffix for functions that raise exceptions (e.g., `File.read!`)
- Non-bang versions should return `{:ok, result}` or `{:error, reason}` tuples
- Only use bang functions when failure is truly exceptional and should crash

**DO:**
```elixir
# Use non-bang when you want to handle errors
case File.read(path) do
  {:ok, content} -> process(content)
  {:error, _} -> use_default_content()
end

# Use bang when failure should crash (e.g., reading config at startup)
content = File.read!("config/required.json")
```

### 8. Documentation

**DO:**
```elixir
@doc """
Processes user input and returns a sanitized list of tags.

## Parameters
  - input: A comma-separated string of tags

## Returns
  - A list of unique, trimmed, lowercase tags

## Examples
    iex> MyApp.process_tags("Elixir, Phoenix, elixir")
    ["elixir", "phoenix"]
"""
def process_tags(input) do
  # implementation
end
```

- Use `@moduledoc` for module-level documentation
- Use `@doc` for public functions
- Include examples using doctests when possible
- Use `@doc false` for private implementation details that must be public

### 9. Avoid Long Functions

- Keep functions small and focused (< 20 lines ideally)
- Extract complex logic into private helper functions
- Each function should do one thing well

**DO:**
```elixir
def parse_and_validate_config(path) do
  with {:ok, content} <- read_config(path),
       {:ok, parsed} <- parse_config(content),
       :ok <- validate_config(parsed) do
    {:ok, parsed}
  end
end

defp read_config(path), do: File.read(path)
defp parse_config(content), do: Jason.decode(content)
defp validate_config(config), do: # validation logic
```

### 10. Structs Over Maps for Domain Models

**DO:**
```elixir
defmodule MyApp.User do
  @enforce_keys [:id, :email]
  defstruct [:id, :email, :name, created_at: DateTime.utc_now()]
end

def create_user(attrs) do
  %MyApp.User{
    id: generate_id(),
    email: attrs.email,
    name: attrs.name
  }
end
```

**DON'T:**
```elixir
def create_user(attrs) do
  %{
    id: generate_id(),
    email: attrs.email,
    name: attrs.name,
    created_at: DateTime.utc_now()
  }
end
```

## CLI Application Specifics

### 1. Use OptionParser for CLI Arguments

```elixir
defmodule MyApp.CLI do
  def main(args) do
    {opts, args, _invalid} = OptionParser.parse(args,
      switches: [verbose: :boolean, output: :string, help: :boolean],
      aliases: [v: :verbose, o: :output, h: :help]
    )

    if opts[:help] do
      print_help()
    else
      run(args, opts)
    end
  end
end
```

### 2. Handle Exit Codes Properly

```elixir
def main(args) do
  case run(args) do
    :ok -> System.halt(0)
    {:error, reason} ->
      IO.puts(:stderr, "Error: #{reason}")
      System.halt(1)
  end
end
```

### 3. Use IO.ANSI for Colored Output (Optional)

```elixir
def print_success(message) do
  IO.puts([IO.ANSI.green(), "✓ ", IO.ANSI.reset(), message])
end

def print_error(message) do
  IO.puts(:stderr, [IO.ANSI.red(), "✗ ", IO.ANSI.reset(), message])
end
```

### 4. Separate CLI Logic from Business Logic

**DO:**
```elixir
# lib/my_app/cli.ex
defmodule MyApp.CLI do
  def main(args) do
    # Parse args, handle I/O
    args
    |> parse_args()
    |> MyApp.Core.process()
    |> format_output()
  end
end

# lib/my_app/core.ex
defmodule MyApp.Core do
  def process(input) do
    # Pure business logic, no I/O
  end
end
```

## Testing

### 1. Test Organization

```elixir
defmodule MyApp.UserServiceTest do
  use ExUnit.Case, async: true
  
  alias MyApp.UserService

  describe "create_user/1" do
    test "creates user with valid attributes" do
      # test implementation
    end

    test "returns error with invalid email" do
      # test implementation
    end
  end
end
```

### 2. Use Doctests

```elixir
defmodule MyApp.Utils do
  @doc """
  Formats a name to title case.

  ## Examples
      iex> MyApp.Utils.format_name("john doe")
      "John Doe"
  """
  def format_name(name), do: # implementation
end

# In test file:
defmodule MyApp.UtilsTest do
  use ExUnit.Case, async: true
  doctest MyApp.Utils
end
```

### 3. Use Pattern Matching in Tests

```elixir
test "returns user with correct structure" do
  assert {:ok, %User{email: email, id: id}} = UserService.create_user(@valid_attrs)
  assert is_binary(email)
  assert is_integer(id)
end
```

## Error Handling

### 1. Use Tagged Tuples

```elixir
{:ok, result}
{:error, :not_found}
{:error, :invalid_input}
{:error, {:validation_failed, details}}
```

### 2. Create Custom Error Modules for Complex Errors

```elixir
defmodule MyApp.ValidationError do
  defexception [:message, :field, :value]

  def exception(opts) do
    field = Keyword.fetch!(opts, :field)
    value = Keyword.fetch!(opts, :value)
    
    %__MODULE__{
      message: "Invalid value for #{field}: #{inspect(value)}",
      field: field,
      value: value
    }
  end
end
```

## Dependencies

### 1. Keep Dependencies Minimal

- Only add dependencies when necessary
- Prefer standard library when possible
- Common CLI deps: `jason` (JSON), `table_rex` (tables), `progress_bar` (progress)

### 2. Specify Versions

```elixir
defp deps do
  [
    {:jason, "~> 1.4"},
    {:ex_doc, "~> 0.31", only: :dev, runtime: false}
  ]
end
```

## Project Structure

```
tiny_ci/
├── lib/
│   ├── tiny_ci.ex           # Main application module
│   ├── tiny_ci/
│   │   ├── cli.ex          # CLI interface
│   │   ├── core.ex         # Business logic
│   │   └── utils.ex        # Utilities
├── test/
│   ├── tiny_ci_test.exs
│   └── tiny_ci/
│       ├── a_test.exs
│       └── another_test.exs
├── mix.exs
├── .formatter.exs
└── README.md
```

## Common Patterns

### 1. Enum Over Recursion (Usually)

**DO:**
```elixir
def sum_list(list), do: Enum.sum(list)
def double_values(list), do: Enum.map(list, &(&1 * 2))
```

Use manual recursion only when Enum functions don't fit or for performance-critical operations.

### 2. Use `case` for Multiple Pattern Matches

```elixir
case user_input do
  "yes" -> proceed()
  "no" -> cancel()
  "help" -> show_help()
  _ -> show_error()
end
```

### 3. Use `cond` for Multiple Boolean Conditions

```elixir
cond do
  temperature < 0 -> :freezing
  temperature < 20 -> :cold
  temperature < 30 -> :warm
  true -> :hot
end
```

## Checklist Before Committing

- [ ] Run `mix format`
- [ ] Run `mix test`
- [ ] Run `mix credo` (if using Credo)
- [ ] Run `mix dialyzer` (if using Dialyxir)
- [ ] Ensure no compiler warnings
- [ ] Update documentation if needed
- [ ] Add tests for new functionality

## Resources

- [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- [Elixir Documentation](https://hexdocs.pm/elixir/)
- [Credo - Static Analysis](https://github.com/rrrene/credo)
- [Dialyxir - Type Checking](https://github.com/jeremyjh/dialyxir)