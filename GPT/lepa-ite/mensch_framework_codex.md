# Mensch Distortion Framework (for Codex Integration)

## Purpose
Provide a structured, voice-aware system of human behavioral distortions aligned with four core energies:
- Logos (thinking)
- Pathos (emotion)
- Ethos (action)
- Anima (life-force)

This framework is used in narrative pipelines (e.g., diary generation) to:
1. Diagnose behavioral patterns from events
2. Guide reflection language
3. Maintain voice consistency across narrators

---

## Core Rule
DO NOT output raw “-mensch” labels in normal narration unless voice == Tommy.

Instead:
- Jim → translate to human observational language
- Southwick → precise, clinical phrasing
- Roger → indirect, trailing implication
- Tommy → may use raw labels

---

## Energy Mapping

### LOGOS (Swords)
Distortions of thinking and identity

- babbelmensch
  - mechanism: talk replaces thought
  - jim_render:
    - "talking so much he never has to think straight"
    - "using words the way a squid uses ink"

- victimensch
  - mechanism: blame externalized
  - jim_render:
    - "a fellow forever keeping the blame outside himself"
    - "can explain every hurt except the part he played in it"

- victlessmensch (paired opposite)
  - mechanism: denial of responsibility
  - jim_render:
    - "won’t admit anything’s his to carry"

---

### PATHOS (Cups)
Distortions of emotional energy

- molotovmensch
  - mechanism: reaction outruns perception
  - jim_render:
    - "carrying a spark like it was a birthright"
    - "anger looking for a doorway"

- sensomensch
  - mechanism: sensation becomes direction
  - jim_render:
    - "letting appetite do the steering"
    - "chasing the next feeling like it meant something permanent"

---

### ETHOS (Pentacles)
Distortions of action and structure

- grabbermensch
  - mechanism: accumulation without purpose
  - jim_render:
    - "taking because taking had become his only skill"
    - "mistaking possession for purpose"

- stupomensch
  - mechanism: avoidance / disengagement
  - jim_render:
    - "dulled down to where even choice seemed like work"
    - "letting life go by so he wouldn’t have to answer it"

---

### ANIMA (Wands)
Distortions of energy flow

- slobbermensch
  - mechanism: overconsumption → stagnation
  - jim_render:
    - "taking in more than could be turned into life"
    - "feeding heaviness and calling it comfort"

- spentmensch
  - mechanism: depletion / burnout
  - jim_render:
    - "burned through more than he knew how to refill"
    - "running on what used to be there"

---

## Pipeline Usage

### Step 1: Event Analysis
Infer 1–2 distortions from story events

### Step 2: Diagnostic Artifact
Example:

```
story_diagnostics:
  primary_distortion: molotovmensch
  energy: pathos
  failure_mode: explosive
```

### Step 3: Reflection Guidance
- Use Jim-style render phrases
- Avoid abstract terminology
- Insert 1–2 natural observations in reflection/realization

---

## Voice Rules (Critical)

- Tommy:
  - Allowed: raw labels (e.g., "molotovmensch")
  - Tone: sharp, mocking

- Jim:
  - Translate to lived observation
  - Tone: grounded, human

- Southwick:
  - Mechanism-level phrasing
  - Tone: precise, minimal

- Roger:
  - Implicit only
  - Tone: drifting, incomplete

---

## Design Principle

These are NOT moral judgments.
They are:

> "Weather patterns of human energy systems."

The goal is recognition and alignment, not condemnation.
