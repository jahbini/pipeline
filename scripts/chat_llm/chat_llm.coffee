###
  scripts/chat_llm/chat_llm.coffee  —  CHAT_LLM pipeline step
  ==========================================================
  Generates chat text from a prompt via the LLM (JS/node-mlx) door.
  Sibling of
    node_modules/@jahbini/pipeline/scripts/prompt_ite/generate_prompt_ite.coffee
  but calls L.callLLM({op:'generate', …}) instead of L.callMLX('generate', …).

  Contract:
    needs: []                          (nothing upstream)
    makes: chat_raw, chat_meta, chat_text
    params:
      quantized_model_dir  → filesystem path to mlx-lm model dir
      prompt_text          → the user prompt (must be non-empty)
      llm                  → optional dict of camelCase generate opts
                             (maxTokens, temperature, topP, systemPrompt)
###

@step =
  desc: "Generate chat text via L.callLLM(generate) and write it to out/"

  action: (L) ->
    prompt = String(L.param('prompt_text', '') ? '').trim()
    throw new Error "[#{L.stepName}] prompt_text must be a non-empty string" unless prompt.length

    modelDir  = L.param 'quantized_model_dir', null
    llmConfig = L.param 'llm', null

    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?
    if llmConfig? and (typeof llmConfig isnt 'object' or Array.isArray(llmConfig))
      throw new Error "[#{L.stepName}] llm must be an object when provided"

    # Assemble the callLLM params. `op` is hardcoded by this step —
    # the recipe/override only supplies data, never the op selector.
    llmArgs =
      op: 'generate'
      modelDir: modelDir
      prompt: prompt

    if llmConfig? and typeof llmConfig is 'object'
      for own key, value of llmConfig
        continue unless value?
        llmArgs[key] = value

    console.log "[chat_llm] modelDir:", modelDir
    console.log "[chat_llm] prompt chars:", prompt.length
    optKeys = if llmConfig? then (k for k of llmConfig).join(', ') else '(none)'
    console.log "[chat_llm] llm opts:", optKeys

    result = await L.callLLM llmArgs

    console.log "[chat_llm] generated #{result.generatedTokens} tokens in #{result.elapsedSec?.toFixed(2) ? '?'}s (#{result.tokPerSec?.toFixed(1) ? '?'} tok/s)"

    meta =
      mode: 'chat_llm'
      model_dir: modelDir
      prompt_chars: prompt.length
      generated_tokens: result.generatedTokens
      prompt_tokens: result.promptTokens
      elapsed_sec: result.elapsedSec
      ttft_sec: result.ttftSec
      tok_per_sec: result.tokPerSec
      peak_mem_gb: result.peakMemGB
      active_mem_gb: result.activeMemGB

    L.make 'chat_raw',  String(result.rawText ? result.text ? '')
    L.make 'chat_meta', meta
    L.make 'chat_text', String(result.text ? '')

    L.done()
    return
