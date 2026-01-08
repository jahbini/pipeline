<script>
  import { memoSnapshot } from '$lib/stores/pipeline';
</script>

<section>
  <h3>Memo Explorer</h3>
  {#each Object.entries($memoSnapshot) as [key, entry]}
    <div class="row">
      <code>{key}</code>
      <div>Resolved: {entry.resolved ? 'yes' : 'no'}</div>
      <div>Value: {JSON.stringify(entry.value)}</div>
    </div>
  {/each}
</section>

<style>
  .row {
    border-bottom: 1px solid #eee;
    padding: 0.5rem 0;
  }
</style>