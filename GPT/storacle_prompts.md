# Storacle prompt-style catalog

A growing collection of storacle prompts and configurations that have been human-verified as producing useful output. Each entry is dated and carries enough provenance that a future reader (human or helper LLM) can reconstruct the conditions and decide whether to try the same shape on a new adapter or model.

**This lives in `puppeteer/GPT/` on purpose.** Prompts and their evaluation notes are cross-adapter, cross-pipe knowledge — they belong with the puppeteer's long-lived project record, not inside individual pipe directories that get wiped when a pipe resets.

**Related structured surface**: `~/writer/GPT/storacle_observations.md` describes a per-run capture system (still to be built). When that ships, THIS file is where the human-authored summary knowledge lives; the observations table is the append-only raw feed.

---

## Placeholders reference

The storacle recipe (as of 2026-09-15) substitutes these placeholders in `prompt_text`:

- `{{{STORY}}}` — full raw story text.
- `{{{FRAGMENT_1}}}` .. `{{{FRAGMENT_5}}}` — the story chunked by `buildStoryGroups` (5 groups when the story has ≥5 paragraphs; 1 group covering the whole thing otherwise). This is the SAME chunker `oracle_ask_sqlite` uses and the SAME chunker `build_lora_dataset_ite` pairs against `chunk_simplifications`. Fragments past the story's actual group count resolve to empty string.

`{{{LEAD_FRAGMENT}}}` was retired 2026-09-15 — the pre-chunk-pair training design it served is gone.

---

## Prompt 1: Full-story Jim-voice rewrite

**Recorded**: 2026-09-15
**Confirmed on**: `hf__qwen__qwen3-0-6b`, adapter from 2026-09-15 training (300 iters, 575 chunk-pairs, `val_loss=4.44`)
**User verdict**: "this prompt could give consistent responses slightly different each time"

### Template

```
<think>rewrite this text from beginning to end
{{{FRAGMENT_1}}}
{{{FRAGMENT_2}}}
{{{FRAGMENT_3}}}
{{{FRAGMENT_4}}}
{{{FRAGMENT_5}}}</think>
```

### Settings

| Knob | Value |
|---|---|
| `temperature` | `0.7` |
| `topP` | `0.9` |
| `repetition_penalty` | `1.15` |
| `use_kag` | `false` |
| `use_chunks` | `false` |
| `adapter_path` | `build/adapter` (or `""` for base baseline) |

### Why it works

1. **All 5 chunks feed inside `<think>`.** The model reads the corpus as its own reasoning, not as user instruction. Prefilled reasoning is weighted higher than the user turn — same principle that turned the failure-classifier from 5/6 to 14/14 correct. See `~/puppeteer/GPT/helper_llm_plan.md` § Implementation status.
2. **In-distribution input.** `FRAGMENT_N` uses `buildStoryGroups` — the same chunker the LoRA saw during training. Whole-story input at inference would be out-of-distribution for a chunk-pair-trained adapter.
3. **Temperature sits at the balance point.** `0.5` gives near-identical rewrites run-to-run (too tight — you can't tell whether the model is thinking or just interpolating from a fixed point). `> 0.8` breaks format. `0.7` preserves paragraph structure and format while letting word choice vary.
4. **Rewrite, not continuation.** The prompt asks for Jim's version of the *same* content, not a continuation from where the story leaves off. That's the actual training axis: bland → spicy of the same content, per chunk.

### How to use for evaluation

- Fire twice with identical settings: once `adapter_path: build/adapter`, once `adapter_path: ""`. The delta is what the adapter learned.
- Fire N times with the adapter to see whether temperature 0.7 gives useful variance (different word choices, same structure) or degenerate variance (loop pathology, hallucinated content).
- On short stories with fewer than 5 paragraphs, `FRAGMENT_2..5` resolve to empty string. The prompt still works; the model sees only `FRAGMENT_1` inside the think block.

### Known limitation (2026-09-15)

The storacle UI does not yet expose `think_prefill`, per-run `temperature`, or `rewrite_llm` overrides. To use this exact template today, put the entire `<think>...</think>` string in the `prompt_text` textarea — the storacle step passes prompts through verbatim after placeholder substitution, so `<think>...</think>` gets embedded in the generation without special handling. That works, but it's fragile — a future storacle refactor might sanitize think tags. Prefer wiring `think_prefill` through the UI properly when the surface grows.

---

## Empty slots (add as we learn)

- Continuation prompt for a single fragment (predict-the-rest-of-story from FRAGMENT_1)
- Comprehension probe ("did X happen in the story?" with a specific event)
- Voice-transfer probe on a *non-Jim* text (does the adapter apply Jim's voice to a novel passage?)
- Style contrast probe (write same content in a different registered voice, then Jim's voice)

Each entry should carry: template, settings, adapter provenance (which training run produced the tested adapter), model, user verdict, and rationale.
