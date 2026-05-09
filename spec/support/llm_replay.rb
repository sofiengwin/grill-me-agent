require "json"

module LlmReplay
  ROOT = File.expand_path("../fixtures/llm_cache", __dir__)

  module_function

  # Load a recorded sequence of OpenAI chat-completion responses from
  # `spec/fixtures/llm_cache/<name>.json`. Each entry is a raw OpenAI API
  # JSON payload that we wrap in a `Langchain::LLM::OpenAIResponse`.
  def load(name)
    path = File.join(ROOT, "#{name}.json")
    raise ArgumentError, "missing LLM replay fixture: #{path}" unless File.exist?(path)

    JSON.parse(File.read(path)).map { |raw| Langchain::LLM::OpenAIResponse.new(raw) }
  end

  # Build a Langchain OpenAI LLM whose `chat` method returns the next
  # response from the named replay fixture, in order. Useful for
  # integration tests that drive `Langchain::Assistant` end-to-end without
  # talking to OpenAI.
  def stub_llm(name, model: "gpt-4o-mini")
    responses = load(name)
    iter = responses.each
    llm = Langchain::LLM::OpenAI.new(api_key: "sk-replay", default_options: { chat_model: model, temperature: 0.0 })
    llm.define_singleton_method(:chat) { |**_kwargs| iter.next }
    llm
  end
end
