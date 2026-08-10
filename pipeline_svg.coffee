#!/usr/bin/env coffee
# experiment.yaml → self-contained SVG for the pipeline UI.
#
# CLI:    coffee pipeline_svg.coffee experiment.yaml > pipeline.svg
# Module: {renderSvg, buildGraph, layout} = require './pipeline_svg.coffee'
#
# The emitted SVG is self-contained (its own <style>) and drops into any
# <div>. Every script node carries data-step="<name>" so the existing UI
# can toggle classes on it just like a row in #steps-body:
#
#   svgRoot.querySelector('[data-step="story_beats"]').classList.add('running')
#
# Status classes: .pending .running .done .failed (styled inside the SVG).
# Native <title> child gives a browser tooltip on hover; the companion
# JS at the bottom of this file wires a nicer HTML popup if you want it.

fs   = require 'fs'
yaml = require 'js-yaml'

RESERVED = ['run', 'artifacts', 'pipeline']

# ---------- graph model ----------
buildGraph = (doc) ->
  artifacts = {}
  for name, spec of (doc.artifacts ? {})
    artifacts[name] = {name, target: spec?.target ? '', producers: [], consumers: []}
  scripts = {}
  for k, v of doc when k not in RESERVED and v?.run?
    scripts[k] = {
      name: k
      run:  v.run
      needs: v.needs ? []
      makes: v.makes ? []
      llm:   v.llm ? null
      quantized: v.quantized_model_dir ? null
      raw:   v
    }
  for name, s of scripts
    for a in s.makes when artifacts[a]?
      artifacts[a].producers.push name
    for a in s.needs when artifacts[a]?
      artifacts[a].consumers.push name
  {scripts, artifacts}

# ---------- layered layout ----------
# Longest-path rank on scripts; artifacts placed between producer and
# earliest consumer. Then 2 barycenter sweeps for row order.
layout = (graph) ->
  {scripts, artifacts} = graph
  rank = {}
  visiting = {}
  computeRank = (name) ->
    return rank[name] if rank[name]?
    throw new Error("cycle at #{name}") if visiting[name]
    visiting[name] = true
    s = scripts[name]
    r = 0
    for a in s.needs when artifacts[a]?
      for prod in artifacts[a].producers
        r = Math.max r, computeRank(prod) + 1
    visiting[name] = false
    rank[name] = r
  computeRank name for name of scripts

  # Artifact rank = producer + 0.5; unproduced artifacts (inputs) sit at 0.
  artRank = {}
  for name, a of artifacts
    prodRanks = (rank[p] for p in a.producers when rank[p]?)
    artRank[name] = if prodRanks.length then Math.max(prodRanks...) + 0.5 else -0.5

  # Column buckets. Scripts on integer ranks, artifacts on X.5.
  columns = {}   # rank -> {scripts: [], artifacts: []}
  for name, r of rank
    columns[r] ?= {scripts: [], artifacts: []}
    columns[r].scripts.push name
  for name, r of artRank
    columns[r] ?= {scripts: [], artifacts: []}
    columns[r].artifacts.push name

  # Initial ordering: alphabetical, gives a deterministic seed.
  for r, col of columns
    col.scripts.sort()
    col.artifacts.sort()

  # 2 barycenter sweeps: order each column by mean y of its neighbors
  # in the previous column. Cheap and good enough at this scale.
  ranks = Object.keys(columns).map(Number).sort (a, b) -> a - b
  ySlots = {}   # nodeId -> row index in its column
  reslot = ->
    for r in ranks
      col = columns[r]
      all = col.scripts.concat(col.artifacts)
      ySlots[n] = i for n, i in all
    return
  reslot()

  neighborBary = (name, otherRank) ->
    # Neighbors of `name` living in column `otherRank`.
    neigh = []
    if scripts[name]?
      s = scripts[name]
      for a in s.needs when artRank[a] == otherRank
        neigh.push a
      for a in s.makes when artRank[a] == otherRank
        neigh.push a
    else if artifacts[name]?
      a = artifacts[name]
      for p in a.producers when rank[p] == otherRank
        neigh.push p
      for c in a.consumers when rank[c] == otherRank
        neigh.push c
    return null if neigh.length == 0
    sum = 0
    sum += ySlots[n] for n in neigh
    sum / neigh.length

  sweep = (dir) ->
    for i in (if dir == 'fwd' then [1...ranks.length] else [ranks.length - 2..0])
      r = ranks[i]
      prev = ranks[i + (if dir == 'fwd' then -1 else 1)]
      col = columns[r]
      all = col.scripts.concat(col.artifacts)
      keyed = all.map (n) -> {n, b: neighborBary(n, prev) ? ySlots[n]}
      keyed.sort (x, y) -> x.b - y.b
      col.scripts   = keyed.filter((k) -> scripts[k.n]?).map (k) -> k.n
      col.artifacts = keyed.filter((k) -> artifacts[k.n]?).map (k) -> k.n
    reslot()

  sweep 'fwd'
  sweep 'bwd'
  sweep 'fwd'

  # Assign coordinates. Tighter than the old boxes-and-notes layout —
  # circles are small and their labels only show on hover, so we can
  # pack rows closer.
  COL_W = 110
  ROW_H = 60
  MARGIN_X = 40
  MARGIN_Y = 20
  positions = {}
  maxRow = 0
  for r in ranks
    col = columns[r]
    all = col.scripts.concat(col.artifacts)
    maxRow = Math.max(maxRow, all.length)
    for n, i in all
      # Center each column vertically around its middle.
      offset = (all.length - 1) / 2
      x = MARGIN_X + (r - ranks[0]) * COL_W
      y = MARGIN_Y + (i - offset) * ROW_H
      positions[n] = {x, y}

  width  = MARGIN_X * 2 + (ranks[ranks.length - 1] - ranks[0]) * COL_W + 80
  # Shift all y so the topmost node sits at MARGIN_Y.
  minY = Math.min (p.y for _, p of positions)...
  for _, p of positions
    p.y += MARGIN_Y - minY
  # Height = actual bottom of content + MARGIN_Y (symmetric with top).
  height = (Math.max (p.y for _, p of positions)...) + MARGIN_Y

  {positions, width, height, ranks, columns}

# ---------- SVG rendering ----------
esc = (s) -> String(s ? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

SCRIPT_R = 16
ART_R    = 10

# Both node kinds render as a single circle. The label is hidden by
# default (opacity 0 via CSS) and pops in on :hover, positioned above
# the circle. Native <title> also gives an OS-level tooltip on hover
# with the full details. Edges are drawn between node centers exactly
# as before — positions[name] is the center.
scriptNode = (s, pos) ->
  cls = ['node', 'script']
  cls.push 'llm' if s.llm? or s.quantized?
  tipLines = [s.name, s.run]
  tipLines.push "temp=#{s.llm.temperature}" if s.llm?.temperature?
  tipLines.push "max=#{s.llm.maxTokens}"    if s.llm?.maxTokens?
  tipLines.push "needs: #{s.needs.join ', '}" if s.needs.length
  tipLines.push "makes: #{s.makes.join ', '}" if s.makes.length
  title = esc tipLines.join('\n')
  labelY = pos.y - SCRIPT_R - 10
  """
    <g class="#{cls.join ' '}" data-step="#{esc s.name}" data-run="#{esc s.run}">
      <title>#{title}</title>
      <circle class="halo" cx="#{pos.x}" cy="#{pos.y}" r="20"/>
      <circle class="node-bg" cx="#{pos.x}" cy="#{pos.y}" r="#{SCRIPT_R}"/>
      <text class="node-label" x="#{pos.x}" y="#{labelY}" text-anchor="middle">#{esc s.name}</text>
    </g>
  """

artifactNode = (a, pos) ->
  cls = ['node', 'artifact']
  cls.push 'terminal' if a.consumers.length == 0 and a.producers.length > 0
  cls.push 'source'   if a.producers.length == 0
  title = esc [a.name, a.target].filter(Boolean).join('\n')
  labelY = pos.y - ART_R - 6
  targetAttr = if a.target then " data-target=\"#{esc a.target}\"" else ''
  """
    <g class="#{cls.join ' '}" data-artifact="#{esc a.name}"#{targetAttr}>
      <title>#{title}</title>
      <circle class="node-bg" cx="#{pos.x}" cy="#{pos.y}" r="#{ART_R}"/>
      <text class="node-label" x="#{pos.x}" y="#{labelY}" text-anchor="middle">#{esc a.name}</text>
    </g>
  """

edgePath = (from, to) ->
  dx = (to.x - from.x) * 0.5
  "M#{from.x},#{from.y} C#{from.x + dx},#{from.y} #{to.x - dx},#{to.y} #{to.x},#{to.y}"

STYLE = """
  .pipeline-svg { font-family: system-ui, sans-serif; font-size: 12px; }
  .pipeline-svg .edge { fill: none; stroke: #b8b0a4; stroke-width: 1.2; }
  .pipeline-svg .edge.needs { stroke-dasharray: 4 3; }
  .pipeline-svg .node .node-bg {
    stroke: #6b6055;
    stroke-width: 1.5;
    fill: #eee6d8;
    transition: fill .15s, stroke .15s, stroke-width .15s;
  }
  .pipeline-svg .node .node-label {
    fill: #2a2620;
    font-weight: 500;
    pointer-events: none;
    opacity: 0;
    transition: opacity .12s;
    paint-order: stroke;
    stroke: rgba(255,255,255,0.85);
    stroke-width: 3;
  }

  /* ─── Base defaults ───────────────────────────────────────────────
     Scripts default to hollow (no fill) so an untagged/pending
     script is unmistakably empty. LLM steps get a blue outline hint. */
  .pipeline-svg .node.script .node-bg { fill: none; stroke: #7a7166; stroke-width: 2; }
  .pipeline-svg .node.script.llm .node-bg { stroke: #3d6fbd; }
  .pipeline-svg .node.artifact .node-bg { fill: none; stroke: #a89a70; stroke-width: 2; }
  .pipeline-svg .node.artifact.terminal .node-bg { stroke: #c04040; stroke-width: 2.5; }
  .pipeline-svg .node.artifact.source   .node-bg { fill: #cfe8b8; stroke: #4a7a4a; stroke-width: 2.5; }

  /* ─── Artifact existence — HOLLOW = empty, SOLID = full ───────────
     produced = file produced (or refreshed) by a step in THIS run   → black
     stale    = file left over from a PREVIOUS run                    → light grey
     absent   = producer step exists but no file on disk yet          → hollow dashed */
  .pipeline-svg .node.artifact.produced .node-bg { fill: #1a1a1a; stroke: #000; stroke-width: 2.5; }
  .pipeline-svg .node.artifact.stale    .node-bg { fill: #d8d4cc; stroke: #9a9284; stroke-width: 2; }
  .pipeline-svg .node.artifact.absent   .node-bg { fill: none;    stroke: #b8ac8a; stroke-width: 1.5; stroke-dasharray: 2 2; }

  /* ─── Script status — big, bold, unmissable ───────────────────────
     pending = hollow gray dashed
     running = BRIGHT ORANGE solid + strong dark outline + pulse + always-visible label
     done    = solid green + dark outline
     failed  = solid red + dark outline */
  .pipeline-svg .node.script.pending .node-bg { fill: none; stroke: #a89a70; stroke-dasharray: 3 2; stroke-width: 1.5; }
  .pipeline-svg .node.script.running .node-bg { fill: #ff9040; stroke: #1a1a1a; stroke-width: 3.5; }
  .pipeline-svg .node.script.done    .node-bg { fill: #3d7a45; stroke: #1a3d1a; stroke-width: 2.5; }
  .pipeline-svg .node.script.failed  .node-bg { fill: #b83048; stroke: #4a1420; stroke-width: 3; }

  /* ── Running is the "look here now" state ──
     Always show the label so the human can name the active step at a
     glance, and pulse the outline so it draws the eye even in
     peripheral vision. */
  .pipeline-svg .node.script.running .node-label { opacity: 1; font-size: 30px; }
  @keyframes pipelinePulse {
    0%, 100% { stroke-width: 3.5; }
    50%      { stroke-width: 6.5; }
  }
  .pipeline-svg .node.script.running .node-bg { animation: pipelinePulse 1.1s ease-in-out infinite; }
  @keyframes pipelineHalo {
    0%, 100% { r: 20; opacity: 0.55; }
    50%      { r: 32; opacity: 0.15; }
  }
  .pipeline-svg .node.script.running .halo {
    fill: #ff9040;
    animation: pipelineHalo 1.4s ease-in-out infinite;
    pointer-events: none;
  }
  .pipeline-svg .node .halo { display: none; }
  .pipeline-svg .node.script.running .halo { display: inline; }

  /* Hover: raise outline + reveal label. */
  .pipeline-svg .node:hover .node-bg { stroke: #000; stroke-width: 3; cursor: pointer; }
  .pipeline-svg .node:hover .node-label { opacity: 1; }
"""

renderSvg = (doc, opts = {}) ->
  graph = buildGraph doc
  lay   = layout graph
  {positions, width, height} = lay

  parts = []
  parts.push """<svg xmlns="http://www.w3.org/2000/svg" class="pipeline-svg" viewBox="0 0 #{width} #{height}" width="100%" preserveAspectRatio="xMidYMid meet">"""
  parts.push "<style>#{STYLE}</style>"

  # Edges first so nodes paint over them.
  parts.push '<g class="edges">'
  for name, s of graph.scripts
    from = positions[name]
    for a in s.makes when positions[a]?
      parts.push """<path class="edge makes" d="#{edgePath from, positions[a]}"/>"""
    for a in s.needs when positions[a]?
      parts.push """<path class="edge needs" d="#{edgePath positions[a], from}"/>"""
  parts.push '</g>'

  parts.push '<g class="nodes">'
  parts.push artifactNode(a, positions[name]) for name, a of graph.artifacts when positions[name]?
  parts.push scriptNode(s, positions[name])   for name, s of graph.scripts   when positions[name]?
  parts.push '</g>'

  parts.push '</svg>'
  parts.join '\n'

module.exports = {buildGraph, layout, renderSvg}

# ---------- CLI ----------
if require.main is module
  file = process.argv[2] ? 'experiment.yaml'
  doc  = yaml.load fs.readFileSync(file, 'utf8')
  process.stdout.write renderSvg(doc) + '\n'
