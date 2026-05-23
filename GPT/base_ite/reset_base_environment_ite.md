Step: `reset_base_environment_ite`
Recipe: `base_ite`

Purpose:
- clear stale SQLite contents and stale training/oracle artifacts before a fresh base seed

Inputs:
- none

Outputs:
- meta write `sqliteResetAll.json`
- removes selected stale files/directories under `build/` and `out/`

Reset contract:
- must reset SQLite through `meta/sqlite.coffee`
- must not unlink `runtime.sqlite`
- must leave the already-open SQLite handle valid for later steps

Current cleanup:
- clears SQLite tables through `sqliteResetAll`
- removes `build/adapter`
- removes `build/train`
- removes `build/model4`
- removes stale `out/*.json`, `out/*.jsonl`, and `out/lora_train.txt` products tied to oracle/lora state

Known pitfalls:
- deleting `runtime.sqlite` here is a critical bug because the runner has already opened SQLite
- stale machines running the old unlink behavior can make `base_ite` appear to finish while no usable DB is created
