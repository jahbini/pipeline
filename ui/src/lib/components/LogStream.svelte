<script>
  import { logs } from '$lib/stores/pipeline';
</script>

<section>
  <h3>Live Logs</h3>
  <div class="logbox">
    {#each $logs as log}
      <div class="line">
        <strong>{log.source}</strong>: {log.message}
      </div>
    {/each}
  </div>
</section>

<style>
  .logbox {
    max-height: 200px;
    overflow-y: auto;
    background: #111;
    color: #0f0;
    padding: 0.5rem;
    font-family: monospace;
  }
</style>