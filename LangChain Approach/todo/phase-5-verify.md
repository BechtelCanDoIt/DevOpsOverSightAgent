# Phase 5 — Demo Rehearsal & Verification

**Goal:** the end-to-end incident triage demo runs in ~5 minutes and a colleague
can stand it up.

## Tasks

- [x] 5.1 `demo/inject-chaos.sh` + `reset.sh` (1-prefixed ports; the `/chaos/error`
      call passes `duration_s` — a latent bug fixed vs the reference).
- [x] 5.2 `demo/script.md` (5 beats, A2A fan-out narrative, approval-via-/chat) +
      `demo/manualdemo.md` (10-step walkthrough).
- [x] 5.3 `Makefile` (demo-up/down, inject/reset-chaos, investigate, rehearse,
      test/test-config/test-a2a, logs, ps).
- [x] 5.4 `tests/runDockerConfigTests.sh` (mesh health + mock tools + chaos cycle)
      and `tests/runA2AConfigTests.sh` (cards resolve + orchestrator health +
      optional investigation).

## Exit criteria

- [x] Both compose files validate; scripts pass `bash -n`.
- [x] `./tests/runUnitTests.sh` green (~250 tests).
- [x] (On a Docker host) `make rehearse` drives inject → investigate → approve →
      reset; one OTel trace spans the flow.
- [x] A colleague can `make demo-up` and run the demo from `demo/script.md`.
