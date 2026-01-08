<script>
  import { pipelineGraph, stepStates } from '$lib/stores/pipeline';
  import { get } from 'svelte/store';

  const colorFor = (state) => ({
    completed: 'lightgreen',
    running: 'lightblue',
    waiting: 'khaki',
    failed: 'salmon',
    frozen: 'lightgray'
  }[state] || 'white');
</script>

<section>
  <h3>Pipeline Graph</h3>
  {#each Object.entries($pipelineGraph) as [name, def]}
    <div class="node" style="background:{colorFor(get(stepStates)[name]?.state)}">
      <strong>{name}</strong>
      {#if def.depends_on.length}
        <div class="deps">← {def.depends_on.join(', ')}</div>
      {/if}
    </div>
  {/each}
</section>

<style>
  .node {
    border: 1px solid #ccc;
    padding: 0.5rem;
    margin: 0.25rem 0;
    border-radius: 4px;
  }
  .deps {
    font-size: 0.8rem;
    color: #555;
  }
</style>