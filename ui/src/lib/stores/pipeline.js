import { writable } from 'svelte/store';

// Central event bus (mock websocket)
export const pipelineGraph = writable({});
export const stepStates = writable({});
export const memoSnapshot = writable({});
export const waitGraph = writable([]);
export const logs = writable([]);

export function mockFeed() {
  // initial graph
  pipelineGraph.set({
    md2segments: { depends_on: [] },
    oracle_ask: { depends_on: ['md2segments'] },
    reply_merge: { depends_on: ['oracle_ask'] },
    rotate_merged: { depends_on: ['reply_merge'] }
  });

  stepStates.set({
    md2segments: { state: 'completed', waiting_for: [] },
    oracle_ask: { state: 'running', waiting_for: [] },
    reply_merge: { state: 'waiting', waiting_for: ['done:oracle_ask'] },
    rotate_merged: { state: 'waiting', waiting_for: ['done:reply_merge'] }
  });

  memoSnapshot.set({
    'done:md2segments': { value: true, resolved: true },
    'done:oracle_ask': { value: null, resolved: false },
    'stories.jsonl': { value: 4821, resolved: true }
  });

  waitGraph.set([
    { from: 'oracle_ask', to: 'done:md2segments' },
    { from: 'reply_merge', to: 'done:oracle_ask' },
    { from: 'rotate_merged', to: 'done:reply_merge' }
  ]);

  let counter = 0;
  const logInterval = setInterval(() => {
    logs.update(l => [
      ...l,
      { source: 'oracle_ask', level: 'info', message: `Processed batch ${++counter}` }
    ]);
    if (counter === 5) {
      stepStates.update(s => ({
        ...s,
        oracle_ask: { state: 'completed', waiting_for: [] },
        reply_merge: { state: 'running', waiting_for: [] }
      }));
      memoSnapshot.update(m => ({
        ...m,
        'done:oracle_ask': { value: true, resolved: true }
      }));
    }
  }, 1500);

  return () => clearInterval(logInterval);
}
