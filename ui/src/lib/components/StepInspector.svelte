<script>
  import { stepStates } from '$lib/stores/pipeline';
</script>

<section>
  <h3>Step Inspector</h3>
  {#each Object.entries($stepStates) as [name, state]}
    <div class="row">
      <strong>{name}</strong>
      <div>Status: {state.state}</div>
      {#if state.waiting_for?.length}
        <div>Waiting for: {state.waiting_for.join(', ')}</div>
      {/if}
    </div>
  {/each}
</section>

<style>
  .row {
    border-bottom: 1px solid #eee;
    padding: 0.5rem 0;
  }
</style>