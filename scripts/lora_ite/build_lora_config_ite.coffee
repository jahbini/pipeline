@step =
  desc: "Write mlx_lm.lora --config YAML (lora_parameters: rank/scale/dropout)"

  action: (L) ->
    # The Memo + meta architecture writes the file: the recipe's
    # `artifacts.lora_config.target` is `data/lora_config.yaml`, the
    # yaml meta rule (/\.yaml$/) fires on the artifact's target path
    # at materialization time, js-yaml writes it. No fs.writeFileSync,
    # no js-yaml import — that work belongs to the meta device, not
    # the step.
    rank    = L.param 'rank',    8
    scale   = L.param 'scale',   20.0
    dropout = L.param 'dropout', 0.0

    config =
      lora_parameters:
        rank: rank
        scale: scale
        dropout: dropout

    L.make 'lora_config', config
    L.done()
    return
