defmodule SymphonyElixir.GitLab.Adapter do
  @moduledoc """
  GitLab project-board tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitLab.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    path = "#{issue_path(issue_id)}/notes"

    case client_module().rest("POST", path, %{}, %{"body" => body}) do
      {:ok, %{} = _response} -> :ok
      {:ok, _response} -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    body = issue_state_update_body(state_name)

    case client_module().rest("PUT", issue_path(issue_id), %{}, body) do
      {:ok, %{} = _response} -> :ok
      {:ok, _response} -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_state_update_body(state_name) do
    if terminal_state?(state_name) do
      %{"state_event" => "close"}
    else
      remove_labels =
        Config.settings!().tracker.active_states
        |> Enum.reject(&same_state?(&1, state_name))
        |> Enum.join(",")

      %{
        "add_labels" => state_name,
        "remove_labels" => remove_labels
      }
    end
  end

  defp issue_path(issue_id) do
    project_path = "/projects/#{URI.encode_www_form(Config.settings!().tracker.project_id)}"
    "#{project_path}/issues/#{URI.encode_www_form(normalize_issue_iid(issue_id))}"
  end

  defp normalize_issue_iid(issue_id) do
    issue_id
    |> String.trim()
    |> String.trim_leading("#")
  end

  defp terminal_state?(state_name), do: same_state?(state_name, "closed")

  defp same_state?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  defp same_state?(_left, _right), do: false

  defp client_module do
    Application.get_env(:symphony_elixir, :gitlab_client_module, Client)
  end
end
