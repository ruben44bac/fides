defimpl AshJsonApi.ToJsonApiError, for: Ash.Error.Changes.StaleRecord do
  use Boundary, classify_to: FidesWeb

  # 409: the record changed since the version the command expected, so nothing changed
  def to_json_api_error(_error) do
    %AshJsonApi.Error{
      id: Ash.UUID.generate(),
      status_code: 409,
      code: "stale",
      title: "Conflict",
      detail: "the application changed after the expected version; read it again and retry",
      source_pointer: "/data/expected_version"
    }
  end
end
