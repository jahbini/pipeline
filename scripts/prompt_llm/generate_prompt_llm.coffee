###
  generate_prompt_llm.coffee  —  PROMPT_LLM pipeline step
  =====================================================================
  Sibling of prompt_ite/generate_prompt_ite.coffee. Drives the in-process
  C++/node-mlx door via L.callLLM({op:'generate', ...}) — no Python spawn.

  (Chunk/RAG retrieval REMOVED — jahbini directive 2026-11-07,
  pipeline/GPT/rag_vs_kag.md. The former rag_top_k path and its per-model
  chunk embeddings are eliminated; KAG keyword context is the retrieval
  mechanism.)

  Legacy hyphenated MLX keys under the yaml `mlx:` block are translated to
  camelCase (max-tokens → maxTokens, temp → temperature, top-p → topP,
  system-prompt → systemPrompt) so existing overrides keep working.
###
fs = require 'fs'

cleanGeneratedText = (prompt, rawOutput) ->
  text = String(rawOutput ? '').trim()
  return '' unless text.length

  if text.indexOf(prompt) is 0
    text = text.slice(prompt.length).trim()

  lines = text.split /\r?\n/
  lines = lines.filter (line) ->
    trimmed = line.trim()
    return false if /^=+$/.test trimmed
    return false if /^Prompt:\s+\d+\s+tokens/.test trimmed
    return false if /^Generation:\s+\d+\s+tokens/.test trimmed
    return false if /^Peak memory:\s+/.test trimmed
    true

  lines.join("\n").trim()

resolveRunTag = (L) ->
  raw = process.env.HH_MM ? L.theLowdown('env/HH_MM')?.value ? null
  return null unless raw?
  text = String(raw).trim()
  text = text.replace(/^"+|"+$/g, '')
  text = text.replace(/^'+|'+$/g, '')
  return null unless text.length
  text

buildDiaryRecord = (prompt, text) ->
  lines = ["Prompt:", prompt, ""]
  lines.push "Generation:", text, ""
  lines.join "\n"

@step =
  desc: "Generate from a UI prompt via L.callLLM(generate)"

  action: (L) ->
    prompt = String(L.param('prompt_text', '') ? '').trim()
    throw new Error "[#{L.stepName}] prompt_text must be a non-empty string" unless prompt.length

    modelDir = L.param 'quantized_model_dir', null
    adapterPath = L.param 'adapter_path', null
    mlxConfig = L.param 'mlx', null
    llmConfig = L.param 'llm', null
    outputPrefix = String(L.param('output_file_prefix', 'prompt_generate') ? 'prompt_generate').trim() or 'prompt_generate'

    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?
    throw new Error "[#{L.stepName}] mlx must be an object when provided" if mlxConfig? and (typeof mlxConfig isnt 'object' or Array.isArray(mlxConfig))
    throw new Error "[#{L.stepName}] llm must be an object when provided" if llmConfig? and (typeof llmConfig isnt 'object' or Array.isArray(llmConfig))

    effectivePrompt = prompt

    llmArgs =
      op: 'generate'
      modelDir: modelDir
      prompt: effectivePrompt
    llmArgs.adapterPath = adapterPath if adapterPath?

    if mlxConfig? and typeof mlxConfig is 'object'
      for own key, value of mlxConfig
        continue unless value?
        camel = switch key
          when 'max-tokens' then 'maxTokens'
          when 'temp', 'temperature' then 'temperature'
          when 'top-p' then 'topP'
          when 'system-prompt' then 'systemPrompt'
          else key
        llmArgs[camel] = value

    if llmConfig? and typeof llmConfig is 'object'
      for own key, value of llmConfig
        continue unless value?
        continue if key is 'op'
        llmArgs[key] = value

    result = await L.callLLM llmArgs
    rawOutput = String(result.rawText ? result.text ? '')
    text = cleanGeneratedText effectivePrompt, rawOutput

    meta =
      mode: 'prompt_generate_llm'
      model_dir: modelDir
      adapter_path: adapterPath ? null
      prompt_chars: prompt.length
      augmented_chars: effectivePrompt.length
      raw_chars: rawOutput.length
      text_chars: text.length
      prompt_tokens: result.promptTokens ? null
      generated_tokens: result.generatedTokens ? null
      elapsed_sec: result.elapsedSec ? null
      ttft_sec: result.ttftSec ? null
      tok_per_sec: result.tokPerSec ? null
      peak_mem_gb: result.peakMemGB ? null

    console.log "[generate_prompt_llm] prompt chars:", prompt.length
    console.log "[generate_prompt_llm] text chars:", text.length
    if result.generatedTokens?
      console.log "[generate_prompt_llm] generated #{result.generatedTokens} tokens" +
        (if result.tokPerSec? then " (#{result.tokPerSec.toFixed(1)} tok/s)" else "")

    L.make 'prompt_generate_raw', rawOutput
    L.make 'prompt_generate_meta', meta
    L.make 'prompt_generate_text', text

    runTag = resolveRunTag L
    if typeof runTag is 'string' and runTag.length
      L.saveThis "out/#{outputPrefix}_#{runTag}.txt", text
      L.saveThis "diary/#{outputPrefix}_#{runTag}.txt", buildDiaryRecord(prompt, text)

    L.done()
    return
