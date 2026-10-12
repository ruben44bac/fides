defimpl AshJsonApi.ToJsonApiError, for: Fides.Origination.TransitionNotAllowed do
  use Boundary, classify_to: FidesWeb

  # 422, with the states the actor may move the application to instead
  def to_json_api_error(error) do
    %AshJsonApi.Error{
      id: Ash.UUID.generate(),
      status_code: 422,
      code: "transition_not_allowed",
      title: "Transition not allowed",
      detail: Fides.Origination.TransitionNotAllowed.summary(error),
      source_pointer: "/data/to",
      meta: %{"from" => error.from, "available" => error.available}
    }
  end
end
