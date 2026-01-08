<script>
  function send(cmd) {
    console.log('CMD:', cmd);
    // Later: websocket.send(JSON.stringify(cmd))
  }
</script>

<section class="controls">
  <h3>Controls</h3>
  <button on:click={() => send({cmd:'freeze'})}>⏸ Freeze</button>
  <button on:click={() => send({cmd:'thaw'})}>▶ Thaw</button>
  <button on:click={() => send({cmd:'step'})}>Step</button>
  <button on:click={() => send({cmd:'invalidate', target:'oracle_ask'})}>Invalidate oracle_ask</button>
</section>

<style>
  .controls button {
    margin-right: 0.5rem;
  }
</style>