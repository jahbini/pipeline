###
  select_diary_events_ite.coffee  —  OBSOLETE
  =====================================================
  **Do not reference from new recipes.** The diary_ite
  pipeline now selects events via the trio
  `story/load_library` + `story/select_story_recipe` +
  `story/resolve_story_parts`. This file is kept only
  so old recipes that name it still resolve at load
  time; expect it to be removed when the runner moves
  to npm.
###
