#!/usr/bin/env coffee
###
test_generate.coffee — sanity-check generation using base model + LoRA adapter
Runs MLX generate BEFORE fuse.
###

@step =
  desc: "Test generation using trained LoRA adapter (pre-fuse)"

  action: (M, stepName) ->

    # ------------------------------------------------------------
    # Load experiment config
    # ------------------------------------------------------------
    cfgEntry = M.theLowdown("experiment.yaml")
    throw new Error "Missing experiment.yaml" unless cfgEntry?.value?

    cfg    = cfgEntry.value
    runCfg = cfg.run

    modelId = runCfg.model
    landKey = runCfg.loraLand

    unless modelId? then throw new Error "Missing run.model"
    unless landKey?  then throw new Error "Missing run.loraLand"

    adapterKey = "#{landKey}/adapter"

    # ------------------------------------------------------------
    # Story prompt
    # ------------------------------------------------------------
    prompt = """
You are a storyteller. Take the voice Pomon and finish the story. Here is the start of the story:
Pomon and Roman are sitting on the shore with me.  As we talk, a porpoise raises its head from the lagoon and chirps softly.
Roman startles, looks very concerned, jumps to his feet, and runs toward the beach shouting,
"It's the octopus! Don't wait up." And he dives into the water and disappears beneath the surface.

I look at Pomon.  She smiles and says, "That's what it's like to be married to a shape-shifter.
He loves the sea, and sometimes he even becomes whatever sea creature calls him."

She goes on to say:
""".trim()

    # ------------------------------------------------------------
    # MLX generate args (adapter applied)
    # ------------------------------------------------------------
    args =
      model: modelId
      prompt: prompt
      "adapter-path": adapterKey
      "max-tokens": 800
      temp: 0.7
      "top-p": 0.9

    console.log "\n=== TEST GENERATION (PRE-FUSE) ===\n"
    console.log prompt
    console.log "\n--- model output ---\n"

    out = M.callMLX "generate", args

    console.log out

    # ------------------------------------------------------------
    # Save output for inspection (optional but useful)
    # ------------------------------------------------------------
    M.saveThis "#{stepName}:prompt", prompt
    M.saveThis "#{stepName}:output", out

    return
