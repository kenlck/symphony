defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, GitLab, Linear}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @gitlab_rest_tool "gitlab_rest"
  @gitlab_rest_description """
  Execute a REST request against the configured GitLab project using Symphony's configured auth.
  """
  @gitlab_rest_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "description" => "HTTP method: GET, POST, PUT, PATCH, or DELETE."
      },
      "path" => %{
        "type" => "string",
        "description" => "GitLab API path under the configured project, for example /projects/:id/issues/:iid/notes."
      },
      "query" => %{
        "type" => ["object", "null"],
        "description" => "Optional query parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "type" => ["object", "null"],
        "description" => "Optional JSON body.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        if tool_supported?(@linear_graphql_tool), do: execute_linear_graphql(arguments, opts), else: unsupported_tool(tool)

      @gitlab_rest_tool ->
        if tool_supported?(@gitlab_rest_tool), do: execute_gitlab_rest(arguments, opts), else: unsupported_tool(tool)

      other ->
        unsupported_tool(other)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case tracker_kind() do
      "gitlab_board" ->
        [
          %{
            "name" => @gitlab_rest_tool,
            "description" => @gitlab_rest_description,
            "inputSchema" => @gitlab_rest_input_schema
          }
        ]

      _ ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Linear.Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_gitlab_rest(arguments, opts) do
    gitlab_client = Keyword.get(opts, :gitlab_client, &GitLab.Client.rest/5)

    with {:ok, method, path, query, body} <- normalize_gitlab_rest_arguments(arguments),
         {:ok, response} <- gitlab_client.(method, path, query, body, []) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_gitlab_rest_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_required_string(arguments, "method", :missing_gitlab_method),
         {:ok, path} <- normalize_required_string(arguments, "path", :missing_gitlab_path),
         {:ok, query} <- normalize_optional_map(arguments, "query", :invalid_gitlab_query),
         {:ok, body} <- normalize_optional_map(arguments, "body", :invalid_gitlab_body) do
      {:ok, method, path, query, body}
    end
  end

  defp normalize_gitlab_rest_arguments(_arguments), do: {:error, :invalid_gitlab_arguments}

  defp normalize_required_string(arguments, key, error) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, error}
    end
  end

  defp normalize_optional_map(arguments, key, error) do
    value =
      cond do
        Map.has_key?(arguments, key) -> Map.get(arguments, key)
        Map.has_key?(arguments, String.to_atom(key)) -> Map.get(arguments, String.to_atom(key))
        true -> nil
      end

    case value do
      value when is_map(value) -> {:ok, value}
      nil -> {:ok, nil}
      _ -> {:error, error}
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload(:invalid_gitlab_arguments) do
    %{
      "error" => %{
        "message" => "`gitlab_rest` expects an object with `method`, `path`, and optional `query` / `body` objects."
      }
    }
  end

  defp tool_error_payload(:missing_gitlab_method) do
    %{"error" => %{"message" => "`gitlab_rest` requires a non-empty `method` string."}}
  end

  defp tool_error_payload(:missing_gitlab_path) do
    %{"error" => %{"message" => "`gitlab_rest` requires a non-empty `path` string."}}
  end

  defp tool_error_payload(:invalid_gitlab_query) do
    %{"error" => %{"message" => "`gitlab_rest.query` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:invalid_gitlab_body) do
    %{"error" => %{"message" => "`gitlab_rest.body` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:missing_gitlab_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitLab auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITLAB_TOKEN`."
      }
    }
  end

  defp tool_error_payload(:invalid_gitlab_method) do
    %{"error" => %{"message" => "`gitlab_rest.method` must be GET, POST, PUT, PATCH, or DELETE."}}
  end

  defp tool_error_payload(:invalid_gitlab_path) do
    %{"error" => %{"message" => "`gitlab_rest.path` must be a relative GitLab API path under the configured project."}}
  end

  defp tool_error_payload(:gitlab_path_outside_project) do
    %{"error" => %{"message" => "`gitlab_rest.path` must stay inside the configured GitLab project."}}
  end

  defp tool_error_payload({:gitlab_api_status, status}) do
    %{
      "error" => %{
        "message" => "GitLab API request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:gitlab_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitLab API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "#{current_tool_label()} tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp tool_supported?(tool), do: tool in supported_tool_names()

  defp unsupported_tool(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  defp tracker_kind do
    Config.settings!().tracker.kind
  rescue
    _ -> "linear"
  end

  defp current_tool_label do
    case tracker_kind() do
      "gitlab_board" -> "GitLab REST"
      _ -> "Linear GraphQL"
    end
  end
end
