###
  scripts/storacle/storacle.coffee — STORACLE pipeline step
  =========================================================
  Prompt-exploration sibling of chat_llm. Takes one of Jim's stories
  (by story_id, chosen from a UI dropdown) and a prompt template (UI
  textarea) that contains the placeholder `{{{STORY}}}`. Substitutes
  the story text into the placeholder and calls L.callLLM({op:'generate'}).

  Purpose: hand-explore prompts for the abliterated Huihui model
  without the ceremony of a full oracle_ite run. One story, one
  prompt, one output — iterate.

  Contract:
    needs: []                            (reads runtime.sqlite directly)
    makes: storacle_raw, storacle_meta, storacle_text
    params:
      quantized_model_dir  → filesystem path to mlx-lm model dir
      story_id             → story_id (kebab-cased) of the story to
                              inject into the prompt
      prompt_text          → prompt template; MUST contain the literal
                              `{{{STORY}}}` placeholder somewhere
      llm                  → optional dict of camelCase generate opts
                              (maxTokens, temperature, topP, systemPrompt)

  Story text lookup: CWD/runtime.sqlite → stories.text WHERE story_id = ?.
###

PLACEHOLDER = '{{{STORY}}}'

# Use the sqlite meta device's `storyByID` request (see
# meta/sqlite.coffee) rather than opening runtime.sqlite directly —
# per the "meta methods for file system access" convention. Returns
# undefined when the story_id isn't in the stories table.
readStoryText = (L, storyId) ->
  row = L.theLowdown("storyByID{#{storyId}}.json")?.value
  row?.text

@step =
  desc: "Substitute {{{STORY}}} in prompt_text with a chosen story's text and call callLLM(generate)"

  action: (L) ->
    template = String(L.param('prompt_text', '') ? '')
    storyId  = String(L.param('story_id', '') ? '').trim()
    modelDir  = L.param 'quantized_model_dir', null
    llmConfig = L.param 'llm', null

    throw new Error "[#{L.stepName}] prompt_text is empty — nothing to send" unless template.trim().length
    throw new Error "[#{L.stepName}] story_id is empty — pick a story from the UI dropdown" unless storyId.length
    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?
    unless template.indexOf(PLACEHOLDER) >= 0
      throw new Error "[#{L.stepName}] prompt_text must contain the placeholder #{PLACEHOLDER} — that's where the story text will be substituted"

    storyText = readStoryText L, storyId
    throw new Error "[#{L.stepName}] no story with story_id='#{storyId}' in CWD/runtime.sqlite" unless storyText?

    # Single-occurrence substitution — replace ALL occurrences so a
    # prompt that references {{{STORY}}} twice (e.g. once for context,
    # once for a re-read pass) works transparently.
    prompt = template.split(PLACEHOLDER).join(storyText)

    console.log "[storacle] story_id: #{storyId} (#{storyText.length} chars)"
    console.log "[storacle] template chars: #{template.length}, effective prompt chars: #{prompt.length}"
    console.log "[storacle] modelDir: #{modelDir}"

    llmArgs =
      op: 'generate'
      modelDir: modelDir
      prompt: prompt
      raw: true                                  # template is fully-formed
    if llmConfig? and typeof llmConfig is 'object' and not Array.isArray(llmConfig)
      for own key, value of llmConfig
        continue unless value?
        llmArgs[key] = value

    result = await L.callLLM llmArgs

    raw = String(result?.rawText ? result?.text ? '')
    console.log "[storacle] generated #{result?.generatedTokens} tokens in #{result?.elapsedSec?.toFixed?(2) ? '?'}s (stop=#{result?.stopMarker ? 'maxTokens'})"

    meta =
      mode: 'storacle'
      model_dir: modelDir
      story_id: storyId
      story_chars: storyText.length
      template_chars: template.length
      prompt_chars: prompt.length
      generated_tokens: result?.generatedTokens ? null
      prompt_tokens: result?.promptTokens ? null
      elapsed_sec: result?.elapsedSec ? null
      tok_per_sec: result?.tokPerSec ? null
      stop_marker: result?.stopMarker ? null
      peak_mem_gb: result?.peakMemGB ? null

    L.make 'storacle_raw', raw
    L.make 'storacle_meta', meta
    L.make 'storacle_text', String(result?.text ? raw)
    L.done()
    return
