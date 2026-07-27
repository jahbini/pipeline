@step =
  desc: "Select story recipe from explicit part keys"

  action: (M, stepName) ->
    overrideScene = M.getStepParam(stepName, 'scene')
    overrideArrival = M.getStepParam(stepName, 'arrival')
    overrideDisturbance = M.getStepParam(stepName, 'disturbance')
    overrideReflection = M.getStepParam(stepName, 'reflection')
    overrideRealization = M.getStepParam(stepName, 'realization')
    libraryKey = "story_library"
    libraryEntry = M.theLowdown libraryKey
    bundle = libraryEntry?.value
    if bundle is undefined
      if typeof libraryEntry?.waitFor is 'function'
        bundle = await libraryEntry.waitFor()
      else if libraryEntry?.notifier?
        bundle = await libraryEntry.notifier
    throw new Error "[#{stepName}] Missing input key '#{libraryKey}'" if bundle is undefined

    recipe = {}
    recipe.scene = overrideScene if overrideScene?
    recipe.arrival = overrideArrival if overrideArrival?
    recipe.disturbance = overrideDisturbance if overrideDisturbance?
    recipe.reflection = overrideReflection if overrideReflection?
    recipe.realization = overrideRealization if overrideRealization?

    for key in ['scene', 'arrival', 'disturbance', 'reflection', 'realization']
      throw new Error "[#{stepName}] missing required recipe key '#{key}'" unless recipe[key]?

    out =
      story_id: null
      recipe: recipe

    M.saveThis "story_recipe", out
    M.saveThis "done:#{stepName}", true
    return
