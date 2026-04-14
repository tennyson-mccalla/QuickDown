# Ingestion Pipeline Architecture

**Owner:** Platform team
**Status:** Approved for Q2 rollout
**Last review:** 2026-03-18

## Overview

The ingestion pipeline accepts event streams from four upstream sources, normalizes them into a canonical schema, and fans out to three consumers: the analytics warehouse, the real-time alerting bus, and the audit log. This document describes the component boundaries, the failure modes we've designed against, and the operational runbook for the oncall rotation.

## Component responsibilities

| Component | Responsibility | Owner |
|-----------|----------------|-------|
| `edge-collector` | Accepts raw events, validates envelopes, enforces rate limits | Platform |
| `normalizer` | Maps vendor schemas to canonical form, drops malformed records | Platform |
| `fanout-router` | Routes canonical events to consumer queues based on event type | Platform |
| `audit-sink` | Durable write-ahead log for compliance replay | Security |
| `warehouse-loader` | Batch-writes to Snowflake every 30 seconds | Data |

## Invariants

1. Every event that enters `edge-collector` either reaches `audit-sink` or is logged as a drop with a reason code. No silent discards.
2. Canonical schema version is monotonic. Consumers must tolerate new optional fields; required fields never change meaning within a major version.
3. End-to-end p99 latency from ingest to warehouse is under 90 seconds under normal load.

## Example canonical envelope

```json
{
  "event_id": "evt_2f9c4a8b1e",
  "source": "mobile-sdk",
  "schema_version": "3.2",
  "ingested_at": "2026-04-13T17:42:01Z",
  "payload": {
    "user_ref": "u_a1b2c3",
    "action": "checkout_completed",
    "amount_cents": 4999
  }
}
```

## Failure modes

- **Upstream flood** — if `edge-collector` queue depth exceeds 80% capacity for 60 seconds, we shed load from low-priority sources first. Priority is configured per-source in `routing.yaml`.
- **Normalizer schema miss** — records that don't match any registered schema go to a dead-letter topic; a daily job alerts if the topic depth is above 500.
- **Warehouse back-pressure** — if Snowflake is unreachable for more than 5 minutes, `warehouse-loader` spills to local disk and resumes when connectivity returns.

## What's next

We're evaluating whether to split `fanout-router` into per-consumer routers to reduce blast radius during deploys. The tradeoff is operational complexity vs. isolation, and we'll have a recommendation by end of Q2.
