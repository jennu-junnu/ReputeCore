# ReputeCore

**Version:** 1.0.0  
**Language:** Clarity (Stacks blockchain)

A cross-protocol reputation aggregation contract that collects raw scores from multiple registered protocol sources and computes a single normalised reputation score (0–1000) for every user. All score submissions and historical snapshots are recorded on-chain for full auditability.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Scoring Model](#scoring-model)
- [Protocol Registry](#protocol-registry)
- [Snapshots & History](#snapshots--history)
- [Limits & Bounds](#limits--bounds)
- [Public Functions](#public-functions)
- [Read-Only Functions](#read-only-functions)
- [Error Codes](#error-codes)
- [Constants Reference](#constants-reference)

---

## Overview

ReputeCore is built around three core ideas:

1. **Multi-source aggregation.** Up to 50 protocols can register as score sources, each with a configurable weight (1–100). A user's reputation is the weighted average of all active protocol scores.
2. **Permissioned submission.** Each protocol designates a single `authorized-submitter` principal. Only that address may push scores for that protocol, keeping data feeds trustworthy.
3. **Immutable history.** On-demand snapshots write the current reputation to an append-only on-chain history map, labelled with a short reason string for full auditability.

---

## How It Works

```
Admin registers protocols (name, weight, authorized-submitter)
         ↓
Protocol submitters call submit-score(user, protocol-id, score)
  └─ raw score stored per (user, protocol-id)
  └─ weighted reputation auto-recalculated and persisted
         ↓
Anyone may call refresh-reputation(user) after a weight change
         ↓
Anyone may call snapshot-reputation(user, reason)
  └─ recalculates first, then writes immutable history entry
         ↓
Consumers query get-weighted-score(user) or compute-live-reputation(user)
```

---

## Scoring Model

User reputation is computed as a **weighted average** across all active protocols:

```
weighted-score = Σ(score_i × weight_i) / Σ(weight_i)
```

Where:
- `score_i` is the raw score for protocol `i`, in the range `[0, 1000]`
- `weight_i` is the protocol's configured weight, in the range `[1, 100]`
- Only **active** protocols contribute; deactivated protocols are excluded (weight treated as 0)
- The result is normalised to `[0, 1000]` — think of it as a score out of 1000, or 0–100%

The maximum intermediate value is `50 × 1000 × 100 = 5,000,000`, well within Clarity's unsigned integer range.

Protocols with no score submission for a given user contribute `0` to that user's `contribution-sum` but do not increase `weight-sum`, so missing data does not unfairly penalise users — only active protocols with actual submissions affect the denominator via the fold accumulator.

---

## Protocol Registry

Each registered protocol has:

| Field | Description |
|-------|-------------|
| `name` | Unique ASCII label (up to 64 chars) |
| `description` | Human-readable description (up to 256 chars) |
| `weight` | Relative influence in the aggregation (1–100) |
| `is-active` | Whether the protocol contributes to score calculations |
| `authorized-submitter` | The only principal allowed to submit scores for this protocol |
| `total-submissions` | Lifetime count of score submissions |
| `created-at` | Block height at registration |

Protocol names are unique. A reverse-lookup map (`protocol-name-to-id`) enforces this and allows lookup by name. Up to **50 protocols** may be registered (hard cap).

---

## Snapshots & History

Snapshots capture a point-in-time view of a user's reputation and write it to an immutable `reputation-history` map. Each snapshot records:

- The weighted score at the time
- The number of active protocols contributing
- The block height
- A short `reason` label (e.g. `"quarterly-review"`, `"grant-application"`)

`snapshot-reputation` always recalculates before writing, guaranteeing consistency. Snapshots are identified by a per-user monotonically increasing `snapshot-id`. They cannot be deleted or overwritten.

---

## Limits & Bounds

| Parameter | Value | Description |
|-----------|-------|-------------|
| `MAX-SCORE` | `u1000` | Maximum raw score a protocol may submit |
| `MIN-WEIGHT` | `u1` | Minimum protocol weight |
| `MAX-WEIGHT` | `u100` | Maximum protocol weight |
| `MAX-PROTOCOLS` | `u50` | Hard cap on registered protocols |

---

## Public Functions

### Administration *(admin only)*

#### `set-admin (new-admin principal)`
Transfers the admin role to a new principal. Only the current admin may call this.

#### `register-protocol (name string-ascii-64) (description string-ascii-256) (weight uint) (authorized-submitter principal)`
Registers a new score-source protocol. Names must be unique. Weight must be between `MIN-WEIGHT` and `MAX-WEIGHT`. Fails if the protocol cap (`MAX-PROTOCOLS`) has been reached. Returns the assigned `protocol-id`.

#### `update-protocol-weight (protocol-id uint) (new-weight uint)`
Updates the scoring weight of an existing protocol. Affects all future aggregations. Call `refresh-reputation` on affected users after changing weights.

#### `update-protocol-submitter (protocol-id uint) (new-submitter principal)`
Replaces the authorized submitter for a protocol.

#### `deactivate-protocol (protocol-id uint)`
Excludes a protocol from future score calculations. Historical scores are preserved but the protocol's weight is treated as `0` during aggregation.

#### `reactivate-protocol (protocol-id uint)`
Re-enables a previously deactivated protocol, restoring its contribution to aggregations.

---

### Score Submission & Aggregation

#### `submit-score (user principal) (protocol-id uint) (score uint)`
Submits or updates a raw reputation score for `user` from the calling protocol. Only the protocol's `authorized-submitter` may call this. Score must be `<= MAX-SCORE`. Automatically recalculates and persists the user's weighted reputation after storing the raw score. Returns the user's new aggregated weighted score.

#### `refresh-reputation (user principal)`
Triggers a fresh weighted aggregation for `user` without submitting a new score. Useful after a protocol weight change or deactivation to bring the stored score up to date. Returns the recalculated weighted score. Permissionless — any principal may call this.

#### `snapshot-reputation (user principal) (reason string-ascii-64)`
Recalculates `user`'s reputation and writes an immutable historical snapshot labelled with `reason`. Permissionless. Returns the new `snapshot-id`.

---

## Read-Only Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `get-admin` | `principal` | Current admin principal |
| `get-protocol-count` | `uint` | Number of protocols ever registered (including inactive) |
| `get-protocol-info (protocol-id uint)` | `(optional protocol)` | Full metadata for a protocol |
| `get-protocol-id-by-name (name string-ascii-64)` | `(optional {protocol-id})` | Look up a protocol's ID by name |
| `get-user-protocol-score (user principal) (protocol-id uint)` | `(optional score-entry)` | Raw score entry for a specific user/protocol pair |
| `get-user-reputation (user principal)` | `(optional reputation)` | Full aggregated reputation record |
| `get-weighted-score (user principal)` | `uint` | Just the numeric weighted score (0 if never calculated) |
| `get-reputation-snapshot (user principal) (snapshot-id uint)` | `(optional snapshot)` | A specific historical snapshot |
| `get-snapshot-count (user principal)` | `uint` | Total snapshots recorded for a user |
| `compute-live-reputation (user principal)` | `tuple` | Live aggregation from current on-chain data **without** persisting — returns `weighted-score`, `active-protocol-count`, `contribution-sum`, and `weight-sum` |

`compute-live-reputation` is particularly useful for previewing the effect of a weight change before committing it, or for off-chain consumers that want a full breakdown rather than just the final score.

---

## Error Codes

| Code | Constant | When it's thrown |
|------|----------|-----------------|
| `u1000` | `ERR-NOT-AUTHORIZED` | Caller is not the admin, or not the protocol's authorized submitter |
| `u1001` | `ERR-PROTOCOL-NOT-FOUND` | Protocol ID does not exist in the registry |
| `u1002` | `ERR-PROTOCOL-ALREADY-EXISTS` | A protocol with that name is already registered |
| `u1003` | `ERR-PROTOCOL-INACTIVE` | Trying to submit a score for a deactivated protocol |
| `u1004` | `ERR-INVALID-SCORE` | Score exceeds `MAX-SCORE` (`u1000`) |
| `u1005` | `ERR-INVALID-WEIGHT` | Weight is outside the `[MIN-WEIGHT, MAX-WEIGHT]` range |
| `u1006` | `ERR-MAX-PROTOCOLS-REACHED` | The 50-protocol hard cap has been reached |

---

## Constants Reference

```clarity
;; Score & Weight Bounds
MAX-SCORE       u1000  ;; 0 = 0%, 1000 = 100%
MIN-WEIGHT      u1
MAX-WEIGHT      u100
MAX-PROTOCOLS   u50    ;; Hard cap on registered protocols

;; Weighted average formula
;; weighted-score = Σ(score_i × weight_i) / Σ(weight_i)
;; Max intermediate value: 50 × 1000 × 100 = 5,000,000
```