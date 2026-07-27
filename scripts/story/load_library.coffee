@step =
  desc: "Load keyed Jim story library YAML"

  action: (M, stepName) ->
    libraryFile = M.getStepParam(stepName, 'library_file')
    libraryEntry = M.theLowdown libraryFile
    doc = libraryEntry?.value
    if doc is undefined
      if typeof libraryEntry?.waitFor is 'function'
        doc = await libraryEntry.waitFor()
      else if libraryEntry?.notifier?
        doc = await libraryEntry.notifier
    throw new Error "[#{stepName}] Missing library_file: #{libraryFile}" if doc is undefined

    unless doc?.library?
      throw new Error "[#{stepName}] Library YAML missing top-level 'library'"
    unless doc?.stories?
      throw new Error "[#{stepName}] Library YAML missing top-level 'stories'"

    out =
      source_file: libraryFile
      library: doc.library
      stories: doc.stories

    M.saveThis "story_library", out
    M.saveThis "done:#{stepName}", true
    return
