---
name: thinking-budget-rescue
description: "When a reasoning model truncates inside <think>, don't retry from scratch — inject \"time's up\" + </think> + { and let it finish from partial reasoning"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d0eb8cb2-39e1-4813-b17d-dda7493cfc5d
---

For any capability that uses `raw:true` + `thinkPrefill` (e.g. `helper_llm.schedule`, `classify_failure`): if the first generate ends inside an open `<think>` block near maxTokens, do NOT immediately fall through to lower-temp retry. Instead, rescue the trajectory by continuing from where it stopped with an injected commitment sentence + `</think>` + `{`.

**Why:** during the 2026-09-17 helper reason-mining sweep, 2 of 7 probes ran out of tokens mid-reasoning with the correct rule already identified in the visible think ("Rule 2 → reset", "Rule 4 applies → reject"). The lower-temp retry starts over and often lands on a different (wrong) rule. Rescuing preserves the reasoning the model already did.

**How to apply — in `runCapability`:**
```
result = await session.generate prompt, {maxTokens, ...}
looksTruncated = not /<\/think>/.test(result.text) and estimatedTokens >= 0.85 * maxTokens
if looksTruncated
  rescuePrompt = originalPrompt + result.text + "\n\nOK, time's up, answering now.\n</think>\n\n{"
  rescue = await session.generate rescuePrompt, {maxTokens: 200, temperature: 0.15}
  try: JSON.parse("{" + rescue.text.replace(/<\|im_end\|>.*$/, ''))
```
If rescue still doesn't parse, fall through to existing lower-temp full retry.

**Compose with KAG:** KAG retrieval shortens the prompt-side few-shot, which frees tokens for reasoning. Rescue caps compute per call. Together they get us to full-answer-in-budget without needing to bump maxTokens further.

Related: [[helper-reason-mining]] (the sweep that surfaced this), [[helper-kag-design]] (the retrieval scheme).
