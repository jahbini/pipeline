# Full Provenance Requirements for Pipeline Scripts

This document defines the additional requirements for scripts that must be **fully compliant** in terms of provenance, validation, and schema safety. These rules extend the baseline pipeline protocol.

---

## 1. Provenance & Metadata
- Each script must record the following in its log or in a sidecar metadata file:
  - Script name
  - Git commit hash (if available)
  - Timestamp of execution
  - Relevant config keys/values that influenced the run
- Metadata must travel with the output (e.g., saved as `<output>.meta.json`).

---

## 2. Parallel Safety
- Scripts must assume other pipeline steps may run concurrently.
- Temporary files must use unique names (e.g., UUID or PID suffix).
- Outputs must not overwrite existing files without explicit versioning or locking.

---

## 3. Validation Hooks
- Scripts should support a config-driven `dry_run` flag.
- In `dry_run` mode, inputs are validated and planned outputs are reported, but no files are written.
- Useful for debugging pipeline configs without committing to execution.

---

## 4. Schema Contracts
- All inputs and outputs must conform to defined schemas (e.g., JSON Schema).
- Scripts must validate incoming files against their schema before use.
- Validation errors must cause an immediate exit with a clear log message.

---

## Summary
- **Minimum protocol** ensures reproducibility and config-driven execution.  
- **Full Provenance** ensures traceability, validation, and robust multi-run safety.  
- Together, they provide a pathway: start quick, finish compliant.
