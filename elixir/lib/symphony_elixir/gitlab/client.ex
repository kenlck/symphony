defmodule SymphonyElixir.GitLab.Client do
  @moduledoc """
  GitLab project issue board client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @issue_page_size 100
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, tracker} <- gitlab_tracker_settings(),
         {:ok, labels} <- active_board_labels(tracker) do
      fetch_open_issues_by_labels(tracker, labels)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    states =
      state_names
      |> Enum.map(&normalize_state_name/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&String.downcase/1)

    if states == [] do
      {:ok, []}
    else
      with {:ok, tracker} <- gitlab_tracker_settings() do
        {terminal_states, active_states} = Enum.split_with(states, &terminal_state?/1)

        with {:ok, terminal_issues} <- fetch_closed_issues_if_needed(tracker, terminal_states),
             {:ok, active_issues} <- fetch_open_issues_by_labels(tracker, active_states) do
          {:ok, uniq_issues(active_issues ++ terminal_issues)}
        end
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids =
      issue_ids
      |> Enum.map(&normalize_issue_iid/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      {:ok, []}
    else
      with {:ok, tracker} <- gitlab_tracker_settings() do
        fetch_issue_states(tracker, ids)
      end
    end
  end

  @spec rest(String.t(), String.t(), map(), map() | nil, keyword()) :: {:ok, term()} | {:error, term()}
  def rest(method, path, query \\ %{}, body \\ nil, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(query) do
    with {:ok, tracker} <- gitlab_tracker_settings(),
         {:ok, normalized_method} <- normalize_method(method),
         :ok <- validate_project_path(path, tracker) do
      request_json(normalized_method, path, query, body, opts)
      |> case do
        {:ok, response_body, _headers} -> {:ok, response_body}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil, Config.settings!().tracker.active_states)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil, [String.t()]) :: Issue.t() | nil
  def normalize_issue_for_test(issue, fallback_state, active_states) when is_map(issue) and is_list(active_states) do
    normalize_issue(issue, fallback_state, active_states)
  end

  @doc false
  @spec project_path_for_test(String.t()) :: String.t()
  def project_path_for_test(project_id), do: project_path(project_id)

  defp active_board_labels(tracker) do
    with {:ok, lists} <- fetch_board_lists(tracker) do
      board_labels =
        lists
        |> Enum.map(&board_list_label_name/1)
        |> Enum.reject(&is_nil/1)

      active_labels =
        tracker.active_states
        |> Enum.filter(fn state ->
          Enum.any?(board_labels, &same_state?(&1, state))
        end)

      {:ok, active_labels}
    end
  end

  defp fetch_board_lists(tracker) do
    path = "#{project_path(tracker.project_id)}/boards/#{URI.encode_www_form(tracker.board_id)}/lists"
    fetch_paginated(path, %{"per_page" => @issue_page_size}, nil)
  end

  defp fetch_open_issues_by_labels(_tracker, []), do: {:ok, []}

  defp fetch_open_issues_by_labels(tracker, labels) do
    labels
    |> Enum.reduce_while({:ok, []}, fn label, {:ok, acc} ->
      query =
        %{
          "state" => "opened",
          "labels" => label,
          "per_page" => @issue_page_size
        }
        |> maybe_put_assignee_filter(tracker.assignee)

      case fetch_paginated("#{project_path(tracker.project_id)}/issues", query, label) do
        {:ok, issues} -> {:cont, {:ok, acc ++ issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, uniq_issues(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_closed_issues_if_needed(_tracker, []), do: {:ok, []}

  defp fetch_closed_issues_if_needed(tracker, _terminal_states) do
    fetch_paginated(
      "#{project_path(tracker.project_id)}/issues",
      %{"state" => "closed", "per_page" => @issue_page_size},
      "closed"
    )
  end

  defp fetch_issue_states(tracker, ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn issue_iid, {:ok, acc} ->
      path = "#{project_path(tracker.project_id)}/issues/#{URI.encode_www_form(issue_iid)}"

      case request_json(:get, path, %{}, nil, []) do
        {:ok, issue, _headers} when is_map(issue) ->
          {:cont, {:ok, acc ++ List.wrap(normalize_issue(issue, nil, tracker.active_states))}}

        {:ok, _unknown, _headers} ->
          {:halt, {:error, :gitlab_unknown_payload}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_paginated(path, query, fallback_state) do
    fetch_paginated(path, query, fallback_state, 1, [])
  end

  defp fetch_paginated(path, query, fallback_state, page, acc) do
    query = Map.put(query, "page", page)

    case request_json(:get, path, query, nil, []) do
      {:ok, items, headers} when is_list(items) ->
        issues =
          items
          |> Enum.map(&normalize_or_keep_board_list(&1, fallback_state))
          |> Enum.reject(&is_nil/1)

        case next_page(headers) do
          nil -> {:ok, acc ++ issues}
          next -> fetch_paginated(path, Map.delete(query, "page"), fallback_state, next, acc ++ issues)
        end

      {:ok, _unknown, _headers} ->
        {:error, :gitlab_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_or_keep_board_list(item, nil), do: item
  defp normalize_or_keep_board_list(item, fallback_state), do: normalize_issue(item, fallback_state, Config.settings!().tracker.active_states)

  defp request_json(method, path, query, body, opts) do
    request_fun = Keyword.get(opts, :request_fun) || Application.get_env(:symphony_elixir, :gitlab_request_fun) || &request/4

    case request_fun.(method, path, query, body) do
      {:ok, %{status: status, body: response_body} = response} when status in 200..299 ->
        {:ok, response_body, Map.get(response, :headers, [])}

      {:ok, response} ->
        Logger.error("GitLab API request failed status=#{response.status} body=#{summarize_error_body(Map.get(response, :body))}")
        {:error, {:gitlab_api_status, response.status}}

      {:error, reason} ->
        Logger.error("GitLab API request failed: #{inspect(reason)}")
        {:error, {:gitlab_api_request, reason}}
    end
  end

  defp request(method, path, query, body) do
    with {:ok, headers} <- gitlab_headers() do
      request_opts =
        [
          method: method,
          url: gitlab_url(path),
          headers: headers,
          params: query,
          connect_options: [timeout: 30_000]
        ]
        |> maybe_put_json_body(body)

      Req.request(request_opts)
    end
  end

  defp maybe_put_json_body(opts, nil), do: opts
  defp maybe_put_json_body(opts, body) when is_map(body), do: Keyword.put(opts, :json, body)

  defp gitlab_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_gitlab_api_token}

      token ->
        {:ok,
         [
           {"PRIVATE-TOKEN", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp gitlab_url(path) do
    Config.settings!().tracker.endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp gitlab_tracker_settings do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) -> {:error, :missing_gitlab_api_token}
      is_nil(tracker.project_id) -> {:error, :missing_gitlab_project_id}
      is_nil(tracker.board_id) -> {:error, :missing_gitlab_board_id}
      true -> {:ok, tracker}
    end
  end

  defp maybe_put_assignee_filter(query, nil), do: query

  defp maybe_put_assignee_filter(query, assignee) when is_binary(assignee) do
    assignee = String.trim(assignee)

    cond do
      assignee == "" -> query
      assignee == "me" -> Map.put(query, "scope", "assigned_to_me")
      String.match?(assignee, ~r/^\d+$/) -> Map.put(query, "assignee_id", assignee)
      true -> Map.put(query, "assignee_username", assignee)
    end
  end

  defp normalize_issue(issue, fallback_state, active_states) when is_map(issue) do
    issue_iid = issue["iid"] || issue[:iid] || issue["id"] || issue[:id]
    labels = extract_labels(issue)
    state = normalize_gitlab_issue_state(issue["state"] || issue[:state], labels, fallback_state, active_states)

    %Issue{
      id: normalize_issue_iid(issue_iid),
      identifier: identifier(issue_iid),
      title: issue["title"] || issue[:title],
      description: issue["description"] || issue[:description],
      priority: parse_priority(issue["weight"] || issue[:weight]),
      state: state,
      branch_name: nil,
      url: issue["web_url"] || issue[:web_url],
      assignee_id: assignee_id(issue),
      blocked_by: [],
      labels: labels,
      assigned_to_worker: true,
      created_at: parse_datetime(issue["created_at"] || issue[:created_at]),
      updated_at: parse_datetime(issue["updated_at"] || issue[:updated_at])
    }
  end

  defp normalize_issue(_issue, _fallback_state, _active_states), do: nil

  defp normalize_gitlab_issue_state("closed", _labels, _fallback_state, _active_states), do: "closed"

  defp normalize_gitlab_issue_state(_state, labels, fallback_state, active_states) do
    Enum.find(active_states, fallback_state, fn active_state ->
      Enum.any?(labels, &same_state?(&1, active_state))
    end)
  end

  defp extract_labels(%{"labels" => labels}) when is_list(labels), do: normalize_labels(labels)
  defp extract_labels(%{labels: labels}) when is_list(labels), do: normalize_labels(labels)
  defp extract_labels(_issue), do: []

  defp normalize_labels(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.downcase/1)
  end

  defp board_list_label_name(%{"label" => %{"name" => name}}) when is_binary(name), do: name
  defp board_list_label_name(%{label: %{name: name}}) when is_binary(name), do: name
  defp board_list_label_name(_list), do: nil

  defp assignee_id(%{"assignee" => %{"id" => id}}), do: to_string(id)
  defp assignee_id(%{"assignees" => [%{"id" => id} | _]}), do: to_string(id)
  defp assignee_id(%{assignee: %{id: id}}), do: to_string(id)
  defp assignee_id(%{assignees: [%{id: id} | _]}), do: to_string(id)
  defp assignee_id(_issue), do: nil

  defp identifier(issue_iid) do
    case normalize_issue_iid(issue_iid) do
      nil -> nil
      iid -> "##{iid}"
    end
  end

  defp normalize_issue_iid(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_issue_iid(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("#")
    |> case do
      "" -> nil
      iid -> iid
    end
  end

  defp normalize_issue_iid(_value), do: nil

  defp normalize_state_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      state -> state
    end
  end

  defp normalize_state_name(value), do: normalize_state_name(to_string(value))

  defp terminal_state?(state), do: same_state?(state, "closed")

  defp same_state?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  defp same_state?(_left, _right), do: false

  defp uniq_issues(issues) do
    issues
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil

  defp normalize_method(method) do
    case method |> String.downcase() |> String.trim() do
      "get" -> {:ok, :get}
      "post" -> {:ok, :post}
      "put" -> {:ok, :put}
      "patch" -> {:ok, :patch}
      "delete" -> {:ok, :delete}
      _ -> {:error, :invalid_gitlab_method}
    end
  end

  defp validate_project_path(path, tracker) do
    project_path = project_path(tracker.project_id)

    cond do
      not String.starts_with?(path, "/") ->
        {:error, :invalid_gitlab_path}

      String.contains?(path, "://") or String.contains?(path, "..") ->
        {:error, :invalid_gitlab_path}

      path == project_path or String.starts_with?(path, project_path <> "/") ->
        :ok

      true ->
        {:error, :gitlab_path_outside_project}
    end
  end

  defp project_path(project_id), do: "/projects/#{URI.encode_www_form(to_string(project_id))}"

  defp next_page(headers) do
    headers
    |> header_value("x-next-page")
    |> case do
      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          value == "" -> nil
          String.match?(value, ~r/^\d+$/) -> String.to_integer(value)
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp header_value(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {header_key, value} when is_binary(header_key) ->
        if String.downcase(header_key) == key, do: List.wrap(value) |> List.first()

      _ ->
        nil
    end)
  end

  defp header_value(headers, key) when is_map(headers) do
    Map.get(headers, key) || Map.get(headers, String.to_atom(key))
  end

  defp header_value(_headers, _key), do: nil

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
