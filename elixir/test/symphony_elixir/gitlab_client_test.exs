defmodule SymphonyElixir.GitLabClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitLab.Client, as: GitLabClient

  test "normalizes GitLab issues using board labels as states" do
    issue =
      GitLabClient.normalize_issue_for_test(
        %{
          "iid" => 42,
          "title" => "Add GitLab board support",
          "description" => "Use issue boards",
          "state" => "opened",
          "weight" => 2,
          "labels" => ["In Progress", "Backend"],
          "web_url" => "https://gitlab.example/group/project/-/issues/42",
          "assignee" => %{"id" => 7},
          "created_at" => "2026-05-01T10:00:00Z",
          "updated_at" => "2026-05-02T10:00:00Z"
        },
        nil,
        ["Todo", "In Progress"]
      )

    assert %Issue{} = issue
    assert issue.id == "42"
    assert issue.identifier == "#42"
    assert issue.priority == 2
    assert issue.state == "In Progress"
    assert issue.labels == ["in progress", "backend"]
    assert issue.assignee_id == "7"
  end

  test "closed GitLab issues normalize to terminal closed state" do
    issue =
      GitLabClient.normalize_issue_for_test(
        %{"iid" => 9, "title" => "Done", "state" => "closed", "labels" => ["Todo"]},
        "Todo",
        ["Todo"]
      )

    assert issue.state == "closed"
  end

  test "fetch_candidate_issues reads board labels and fetches opened issues for active states" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab_board",
      tracker_endpoint: "https://gitlab.example/api/v4",
      tracker_project_id: "group/project",
      tracker_board_id: "12",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["closed"]
    )

    test_pid = self()

    Application.put_env(:symphony_elixir, :gitlab_request_fun, fn method, path, query, body ->
      send(test_pid, {:gitlab_request, method, path, query, body})

      case {method, path, query["labels"]} do
        {:get, "/projects/group%2Fproject/boards/12/lists", _} ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"label" => %{"name" => "Todo"}},
               %{"label" => %{"name" => "In Progress"}},
               %{"label" => %{"name" => "Review"}}
             ],
             headers: []
           }}

        {:get, "/projects/group%2Fproject/issues", "Todo"} ->
          {:ok,
           %{
             status: 200,
             body: [%{"iid" => 1, "title" => "Todo issue", "state" => "opened", "labels" => ["Todo"]}],
             headers: []
           }}

        {:get, "/projects/group%2Fproject/issues", "In Progress"} ->
          {:ok,
           %{
             status: 200,
             body: [%{"iid" => 2, "title" => "Active issue", "state" => "opened", "labels" => ["In Progress"]}],
             headers: []
           }}
      end
    end)

    assert {:ok, issues} = GitLabClient.fetch_candidate_issues()
    assert Enum.map(issues, & &1.identifier) == ["#1", "#2"]
    assert Enum.map(issues, & &1.state) == ["Todo", "In Progress"]
  end

  test "fetch_issue_states_by_ids fetches each configured project issue by iid" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab_board",
      tracker_endpoint: "https://gitlab.example/api/v4",
      tracker_project_id: "group/project",
      tracker_board_id: "12",
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["closed"]
    )

    Application.put_env(:symphony_elixir, :gitlab_request_fun, fn
      :get, "/projects/group%2Fproject/issues/1", %{}, nil ->
        {:ok, %{status: 200, body: %{"iid" => 1, "title" => "One", "state" => "opened", "labels" => ["Todo"]}, headers: []}}

      :get, "/projects/group%2Fproject/issues/2", %{}, nil ->
        {:ok, %{status: 200, body: %{"iid" => 2, "title" => "Two", "state" => "closed", "labels" => []}, headers: []}}
    end)

    assert {:ok, [first, second]} = GitLabClient.fetch_issue_states_by_ids(["#1", "2"])
    assert first.state == "Todo"
    assert second.state == "closed"
  end

  test "gitlab_rest enforces configured project scope" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab_board",
      tracker_endpoint: "https://gitlab.example/api/v4",
      tracker_project_id: "group/project",
      tracker_board_id: "12"
    )

    assert {:error, :gitlab_path_outside_project} =
             GitLabClient.rest("GET", "/projects/other/issues/1", %{}, nil,
               request_fun: fn _method, _path, _query, _body ->
                 flunk("request should not run for paths outside configured project")
               end
             )

    assert {:ok, %{"iid" => 1}} =
             GitLabClient.rest("GET", "/projects/group%2Fproject/issues/1", %{}, nil,
               request_fun: fn :get, "/projects/group%2Fproject/issues/1", %{}, nil ->
                 {:ok, %{status: 200, body: %{"iid" => 1}, headers: []}}
               end
             )
  end
end
