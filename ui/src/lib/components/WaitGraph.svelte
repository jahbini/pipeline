<script>
  import { waitGraph } from '$lib/stores/pipeline';
</script>

<section>
  <h3>Wait Graph</h3>
  {#each $waitGraph as edge}
    <div class="edge">
      {edge.from} → {edge.to}
    </div>
  {/each}
</section>

<style>
  .edge {
    font-size: 0.9rem;
    color: #444;
  }
</style>