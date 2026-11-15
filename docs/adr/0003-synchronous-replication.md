# 0003: Synchronous replication, strictly enforced

## Constraint

A write that the application was told succeeded must still exist after any single node is lost.

## Decision

Run PostgreSQL with three instances, one per node, managed by CloudNativePG. Replication is synchronous: a commit is acknowledged only after at least one standby has received it (`method: any`, `number: 1`).

Durability is set to `required`. If no standby is available, PostgreSQL stops acknowledging writes instead of quietly continuing in asynchronous mode.

## Consequence

- Losing the primary loses no acknowledged write: the standby that is promoted already has it. `make drill` checks this on every run.
- Every write waits for a second node, so write latency includes a network round trip.
- With one node down, writes continue: the remaining standby is enough. With two nodes down, writes stop. This is deliberate: the alternative is accepting writes that a further failure could lose.
- Availability is traded for durability. For data where losing the last few seconds is acceptable, `preferred` would be the better setting.
