;; title: ReputeCore
;; version: 1.0.0
;; summary: Cross-protocol reputation aggregation with weighted scoring and historical on-chain performance tracking
;; description: ReputeCore aggregates reputation scores submitted by multiple registered protocols using
;;              configurable per-protocol weights to compute a single normalized reputation score (0-1000)
;;              for every user. All score submissions and snapshots are recorded on-chain for full auditability.

;; ============================================================
;; CONSTANTS
;; ============================================================

(define-constant CONTRACT-OWNER tx-sender)

;; Score & weight bounds
(define-constant MAX-SCORE     u1000) ;; 0 = 0 %, 1000 = 100 %
(define-constant MIN-WEIGHT    u1)
(define-constant MAX-WEIGHT    u100)
(define-constant MAX-PROTOCOLS u50)  ;; Hard cap on registered protocols

;; Error codes
(define-constant ERR-NOT-AUTHORIZED          (err u1000))
(define-constant ERR-PROTOCOL-NOT-FOUND      (err u1001))
(define-constant ERR-PROTOCOL-ALREADY-EXISTS (err u1002))
(define-constant ERR-PROTOCOL-INACTIVE       (err u1003))
(define-constant ERR-INVALID-SCORE           (err u1004))
(define-constant ERR-INVALID-WEIGHT          (err u1005))
(define-constant ERR-MAX-PROTOCOLS-REACHED   (err u1006))

;; ============================================================
;; DATA VARS
;; ============================================================

;; Current administrator (defaults to deployer)
(define-data-var admin principal CONTRACT-OWNER)

;; Monotonically increasing counter - also serves as the next protocol ID
(define-data-var protocol-nonce uint u0)

;; ============================================================
;; DATA MAPS
;; ============================================================

;; Core protocol registry
(define-map protocol-registry
  { protocol-id: uint }
  {
    name:                 (string-ascii 64),
    description:          (string-ascii 256),
    weight:               uint,      ;; Relative weight (1-100)
    is-active:            bool,
    authorized-submitter: principal, ;; Only this principal may submit scores
    total-submissions:    uint,      ;; Lifetime submission counter
    created-at:           uint       ;; Block height at registration
  }
)

;; Reverse-lookup: protocol name -> protocol-id (enforces name uniqueness)
(define-map protocol-name-to-id
  { name: (string-ascii 64) }
  { protocol-id: uint }
)

;; Per-user, per-protocol raw score entry
(define-map user-protocol-scores
  { user: principal, protocol-id: uint }
  {
    score:            uint, ;; Raw score 0-1000
    last-updated:     uint, ;; Block height of most recent update
    submission-count: uint  ;; Times this entry has been updated
  }
)

;; Aggregated weighted reputation for each user
(define-map user-reputation
  { user: principal }
  {
    weighted-score:        uint, ;; Normalized score 0-1000
    active-protocol-count: uint, ;; Protocols with active submissions
    last-calculated:       uint, ;; Block height of last recalculation
    snapshot-count:        uint  ;; Total historical snapshots taken
  }
)

;; Immutable historical reputation snapshots
(define-map reputation-history
  { user: principal, snapshot-id: uint }
  {
    weighted-score:        uint,
    active-protocol-count: uint,
    block-height:          uint,
    reason:                (string-ascii 64)
  }
)

;; ============================================================
;; PRIVATE HELPERS
;; ============================================================

;; True when the caller is the current admin
(define-private (is-admin)
  (is-eq tx-sender (var-get admin))
)

;; Returns a protocol's weight if it is active, otherwise 0
(define-private (get-active-weight (protocol-id uint))
  (match (map-get? protocol-registry { protocol-id: protocol-id })
    p (if (get is-active p) (get weight p) u0)
    u0
  )
)

;; Returns a user's raw score for a protocol (0 if not set)
(define-private (get-raw-score (user principal) (protocol-id uint))
  (match (map-get? user-protocol-scores { user: user, protocol-id: protocol-id })
    entry (get score entry)
    u0
  )
)

;; fold accumulator - accumulates weighted contributions across all protocol slots
;;
;; Weighted score formula (result stays in 0-1000 range):
;;   weighted-score = sum(score_i * weight_i) / sum(weight_i)
;;
;; Where score_i in [0, 1000] and weight_i in [1, 100].
;; Maximum contribution-sum = 50 * 1000 * 100 = 5,000,000 (well within u128).
(define-private (fold-score
    (protocol-id uint)
    (acc { user: principal, contribution-sum: uint, weight-sum: uint, active-count: uint })
  )
  (let ((w (get-active-weight protocol-id)))
    (if (> w u0)
      {
        user:             (get user acc),
        contribution-sum: (+ (get contribution-sum acc)
                             (* (get-raw-score (get user acc) protocol-id) w)),
        weight-sum:       (+ (get weight-sum acc) w),
        active-count:     (+ (get active-count acc) u1)
      }
      acc
    )
  )
)

;; Fixed list covering all 50 protocol ID slots used by fold-score
(define-private (all-protocol-ids)
  (list
    u1  u2  u3  u4  u5  u6  u7  u8  u9  u10
    u11 u12 u13 u14 u15 u16 u17 u18 u19 u20
    u21 u22 u23 u24 u25 u26 u27 u28 u29 u30
    u31 u32 u33 u34 u35 u36 u37 u38 u39 u40
    u41 u42 u43 u44 u45 u46 u47 u48 u49 u50
  )
)

;; Runs the weighted aggregation and persists the result for `user`.
;; Returns the new weighted score.
(define-private (recalculate-reputation (user principal))
  (let (
    (result (fold fold-score
               (all-protocol-ids)
               { user: user, contribution-sum: u0, weight-sum: u0, active-count: u0 }))
    (new-score
      (if (> (get weight-sum result) u0)
        (/ (get contribution-sum result) (get weight-sum result))
        u0
      )
    )
    (prev-snapshot-count
      (match (map-get? user-reputation { user: user })
        rep (get snapshot-count rep)
        u0
      )
    )
  )
    (map-set user-reputation
      { user: user }
      {
        weighted-score:        new-score,
        active-protocol-count: (get active-count result),
        last-calculated:       stacks-block-height,
        snapshot-count:        prev-snapshot-count
      }
    )
    new-score
  )
)

;; Reads the current persisted reputation for `user` and writes it to history.
;; Returns the new snapshot-id.
(define-private (write-snapshot (user principal) (reason (string-ascii 64)))
  (let (
    (rep (default-to
           { weighted-score: u0, active-protocol-count: u0,
             last-calculated: u0, snapshot-count: u0 }
           (map-get? user-reputation { user: user })))
    (new-snapshot-id (+ (get snapshot-count rep) u1))
  )
    (map-set reputation-history
      { user: user, snapshot-id: new-snapshot-id }
      {
        weighted-score:        (get weighted-score rep),
        active-protocol-count: (get active-protocol-count rep),
        block-height:          stacks-block-height,
        reason:                reason
      }
    )
    (map-set user-reputation
      { user: user }
      (merge rep { snapshot-count: new-snapshot-id })
    )
    new-snapshot-id
  )
)

;; ============================================================
;; PUBLIC FUNCTIONS - Administration
;; ============================================================

;; Transfer the admin role to a new principal
(define-public (set-admin (new-admin principal))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (var-set admin new-admin)
    (ok true)
  )
)

;; Register a new protocol source.
;; Only the admin can call this; protocol names must be unique.
;; Returns the assigned protocol-id.
(define-public (register-protocol
    (name                 (string-ascii 64))
    (description          (string-ascii 256))
    (weight               uint)
    (authorized-submitter principal)
  )
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (asserts! (is-none (map-get? protocol-name-to-id { name: name }))
              ERR-PROTOCOL-ALREADY-EXISTS)
    (asserts! (and (>= weight MIN-WEIGHT) (<= weight MAX-WEIGHT)) ERR-INVALID-WEIGHT)
    (asserts! (< (var-get protocol-nonce) MAX-PROTOCOLS) ERR-MAX-PROTOCOLS-REACHED)
    (let ((new-id (+ (var-get protocol-nonce) u1)))
      (var-set protocol-nonce new-id)
      (map-set protocol-registry
        { protocol-id: new-id }
        {
          name:                 name,
          description:          description,
          weight:               weight,
          is-active:            true,
          authorized-submitter: authorized-submitter,
          total-submissions:    u0,
          created-at:           stacks-block-height
        }
      )
      (map-set protocol-name-to-id { name: name } { protocol-id: new-id })
      (ok new-id)
    )
  )
)

;; Update the scoring weight of an existing protocol
(define-public (update-protocol-weight (protocol-id uint) (new-weight uint))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= new-weight MIN-WEIGHT) (<= new-weight MAX-WEIGHT)) ERR-INVALID-WEIGHT)
    (match (map-get? protocol-registry { protocol-id: protocol-id })
      p   (begin
            (map-set protocol-registry
              { protocol-id: protocol-id }
              (merge p { weight: new-weight }))
            (ok true)
          )
      ERR-PROTOCOL-NOT-FOUND
    )
  )
)

;; Replace the authorized submitter for a protocol
(define-public (update-protocol-submitter (protocol-id uint) (new-submitter principal))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (match (map-get? protocol-registry { protocol-id: protocol-id })
      p   (begin
            (map-set protocol-registry
              { protocol-id: protocol-id }
              (merge p { authorized-submitter: new-submitter }))
            (ok true)
          )
      ERR-PROTOCOL-NOT-FOUND
    )
  )
)

;; Deactivate a protocol - its historical scores are preserved but excluded from future calculations
(define-public (deactivate-protocol (protocol-id uint))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (match (map-get? protocol-registry { protocol-id: protocol-id })
      p   (begin
            (map-set protocol-registry
              { protocol-id: protocol-id }
              (merge p { is-active: false }))
            (ok true)
          )
      ERR-PROTOCOL-NOT-FOUND
    )
  )
)

;; Re-enable a previously deactivated protocol
(define-public (reactivate-protocol (protocol-id uint))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (match (map-get? protocol-registry { protocol-id: protocol-id })
      p   (begin
            (map-set protocol-registry
              { protocol-id: protocol-id }
              (merge p { is-active: true }))
            (ok true)
          )
      ERR-PROTOCOL-NOT-FOUND
    )
  )
)

;; ============================================================
;; PUBLIC FUNCTIONS - Score Submission & Aggregation
;; ============================================================

;; Submit or update a reputation score for `user` from a registered protocol.
;; Only the protocol's designated authorized-submitter may call this function.
;; Automatically recalculates and persists the user's weighted reputation.
;; Returns the user's new aggregated weighted score.
(define-public (submit-score (user principal) (protocol-id uint) (score uint))
  (begin
    (asserts! (<= score MAX-SCORE) ERR-INVALID-SCORE)
    (match (map-get? protocol-registry { protocol-id: protocol-id })
      p (begin
          (asserts! (is-eq tx-sender (get authorized-submitter p)) ERR-NOT-AUTHORIZED)
          (asserts! (get is-active p) ERR-PROTOCOL-INACTIVE)
          (let (
            (prev (default-to
                    { score: u0, last-updated: u0, submission-count: u0 }
                    (map-get? user-protocol-scores { user: user, protocol-id: protocol-id })))
          )
            ;; Persist the new score entry
            (map-set user-protocol-scores
              { user: user, protocol-id: protocol-id }
              {
                score:            score,
                last-updated:     stacks-block-height,
                submission-count: (+ (get submission-count prev) u1)
              }
            )
            ;; Increment the protocol's lifetime submission counter
            (map-set protocol-registry
              { protocol-id: protocol-id }
              (merge p { total-submissions: (+ (get total-submissions p) u1) })
            )
            ;; Recompute and return the user's aggregated score
            (ok (recalculate-reputation user))
          )
        )
      ERR-PROTOCOL-NOT-FOUND
    )
  )
)

;; Trigger a fresh aggregation for `user` without submitting a new score.
;; Useful after a protocol weight change or deactivation.
;; Returns the recalculated weighted score.
(define-public (refresh-reputation (user principal))
  (ok (recalculate-reputation user))
)

;; Record an immutable on-chain snapshot of `user`'s current reputation.
;; Recalculates before snapshotting to guarantee consistency.
;; `reason` is a short label (e.g. "quarterly-review", "grant-application").
;; Returns the new snapshot-id.
(define-public (snapshot-reputation (user principal) (reason (string-ascii 64)))
  (let ((refreshed-score (recalculate-reputation user)))
    (ok (write-snapshot user reason))
  )
)

;; ============================================================
;; READ-ONLY FUNCTIONS
;; ============================================================

;; Current admin principal
(define-read-only (get-admin)
  (var-get admin)
)

;; Number of protocols ever registered (includes inactive ones)
(define-read-only (get-protocol-count)
  (var-get protocol-nonce)
)

;; Full metadata for a specific protocol
(define-read-only (get-protocol-info (protocol-id uint))
  (map-get? protocol-registry { protocol-id: protocol-id })
)

;; Look up a protocol's numeric ID by name
(define-read-only (get-protocol-id-by-name (name (string-ascii 64)))
  (map-get? protocol-name-to-id { name: name })
)

;; A user's raw score entry for a specific protocol
(define-read-only (get-user-protocol-score (user principal) (protocol-id uint))
  (map-get? user-protocol-scores { user: user, protocol-id: protocol-id })
)

;; Full aggregated reputation record for a user
(define-read-only (get-user-reputation (user principal))
  (map-get? user-reputation { user: user })
)

;; Convenience accessor - just the numeric weighted score (0 if never calculated)
(define-read-only (get-weighted-score (user principal))
  (match (map-get? user-reputation { user: user })
    rep (get weighted-score rep)
    u0
  )
)

;; A specific historical snapshot
(define-read-only (get-reputation-snapshot (user principal) (snapshot-id uint))
  (map-get? reputation-history { user: user, snapshot-id: snapshot-id })
)

;; Total number of snapshots recorded for a user
(define-read-only (get-snapshot-count (user principal))
  (match (map-get? user-reputation { user: user })
    rep (get snapshot-count rep)
    u0
  )
)

;; Compute a live reputation score from current on-chain data WITHOUT persisting it.
;; Returns a detailed breakdown: weighted-score, active-protocol-count,
;; contribution-sum, and weight-sum.
(define-read-only (compute-live-reputation (user principal))
  (let (
    (result (fold fold-score
               (all-protocol-ids)
               { user: user, contribution-sum: u0, weight-sum: u0, active-count: u0 }))
  )
    {
      weighted-score:
        (if (> (get weight-sum result) u0)
          (/ (get contribution-sum result) (get weight-sum result))
          u0),
      active-protocol-count: (get active-count result),
      contribution-sum:      (get contribution-sum result),
      weight-sum:            (get weight-sum result)
    }
  )
)
