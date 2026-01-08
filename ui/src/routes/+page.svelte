<script>
  import { onMount } from 'svelte';
  import { mockFeed } from '$lib/stores/pipeline';

  import PipelineGraph from '$lib/components/PipelineGraph.svelte';
  import StepInspector from '$lib/components/StepInspector.svelte';
  import MemoExplorer from '$lib/components/MemoExplorer.svelte';
  import WaitGraph from '$lib/components/WaitGraph.svelte';
  import ExecutionControls from '$lib/components/ExecutionControls.svelte';
  import LogStream from '$lib/components/LogStream.svelte';

  onMount(() => {
    const stop = mockFeed();
    return stop;
  });
</script>

<h1>Pipeline Viewer</h1>

<div class="grid">
  <PipelineGraph />
  <StepInspector />
  <MemoExplorer />
  <WaitGraph />
</div>

<ExecutionControls />
<LogStream />

<style>
  .grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    grid-gap: 1rem;
    margin-bottom: 1rem;
  }
</style>