defmodule Fides.Notifications.Templates do
  @moduledoc """
  The notices an applicant gets, in the language of their country: that information
  is needed, that the application was approved, or that it was rejected. Texts carry
  the application's reference and nothing about the holder.
  """

  @languages %{"ES" => "es", "PT" => "pt", "IT" => "it", "MX" => "es", "CO" => "es", "BR" => "pt"}

  @texts %{
    {:info_requested, "es"} =>
      {"Tu solicitud de crédito necesita información adicional",
       "Para continuar con la evaluación de tu solicitud %{reference} necesitamos información adicional. Ingresa a tu cuenta para completarla."},
    {:approved, "es"} =>
      {"Tu solicitud de crédito fue aprobada",
       "Tu solicitud %{reference} fue aprobada. En breve recibirás los pasos para continuar."},
    {:rejected, "es"} =>
      {"Tu solicitud de crédito no fue aprobada",
       "Tu solicitud %{reference} no fue aprobada en esta ocasión. Puedes volver a solicitar más adelante."},
    {:info_requested, "pt"} =>
      {"O seu pedido de crédito precisa de informação adicional",
       "Para continuar a avaliação do seu pedido %{reference} precisamos de informação adicional. Entre na sua conta para a completar."},
    {:approved, "pt"} =>
      {"O seu pedido de crédito foi aprovado",
       "O seu pedido %{reference} foi aprovado. Em breve receberá os próximos passos."},
    {:rejected, "pt"} =>
      {"O seu pedido de crédito não foi aprovado",
       "O seu pedido %{reference} não foi aprovado desta vez. Pode voltar a pedir mais tarde."},
    {:info_requested, "it"} =>
      {"La tua richiesta di credito richiede ulteriori informazioni",
       "Per continuare la valutazione della tua richiesta %{reference} abbiamo bisogno di ulteriori informazioni. Accedi al tuo account per completarla."},
    {:approved, "it"} =>
      {"La tua richiesta di credito è stata approvata",
       "La tua richiesta %{reference} è stata approvata. A breve riceverai i prossimi passi."},
    {:rejected, "it"} =>
      {"La tua richiesta di credito non è stata approvata",
       "La tua richiesta %{reference} non è stata approvata questa volta. Potrai richiedere di nuovo più avanti."}
  }

  @spec templates() :: [atom()]
  def templates, do: [:info_requested, :approved, :rejected]

  @doc "The language of a country's notices."
  @spec language(String.t()) :: String.t()
  def language(country), do: Map.get(@languages, country, "es")

  @doc "The subject and body of a notice, with the application's short reference."
  @spec render(atom(), String.t(), Ecto.UUID.t()) :: {String.t(), String.t()}
  def render(template, language, application_id) do
    {subject, body} = Map.fetch!(@texts, {template, language})
    {subject, String.replace(body, "%{reference}", String.slice(application_id, 0, 8))}
  end
end
