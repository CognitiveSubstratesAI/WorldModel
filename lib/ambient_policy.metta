;; WorldModel/lib/ambient_policy.metta — the AMBIENT (slow-rate) loop's policy, as atoms.
;;
;; `slow_step!` is the §7 background loop: it decides WHICH beliefs have gone stale, HOW URGENT each one
;; is, and HOW MUCH work one pass may do. Every one of those is a policy decision — a threshold, a
;; priority function, a budget — and all three were Julia keyword defaults on `slow_step!`. Defaults, not
;; arguments: `run_cycle!` calls `slow_step!(loop; t=t)` and OmegaClaw's `_ambient_step!` passes only `t`,
;; so the defaults ARE the live policy, just written where nothing can inspect or rewrite them.
;;
;; The standard is set on the other side of the same seam: OmegaClaw's `(= (consolidate-every) 8)` /
;; `(= (consolidate-idle-secs) 600)` decide WHEN this loop runs and are already rewritable atoms. What it
;; DOES when it runs is here.
;;
;; Julia's role on this path is substrate access + the mechanical sort, exposed as grounded atoms:
;;   (wm-belief-rows $h $space)              -> ((row key c0 t0) …)   every current belief
;;   (wm-evidence-count $h $space $key)      -> Int                   |evidence still anchoring key|
;;   (wm-belief-strength $h $space $key)     -> Number | no-belief     current strength (preserved)
;;   (wm-put-belief! $h $space $k $s $c $t)  -> ()                     write it back
;; `$h` is a registry HANDLE token — the SpaceRegistry never crosses the ABI.

;; ── budgets and thresholds ───────────────────────────────────────────────────────────────────────
;; A belief is a re-validation candidate once its DECAYED confidence falls below this. There used to be
;; two disagreeing Julia values for this one concept — `slow_step!`'s `threshold=0.3` and
;; `stale_beliefs`' `threshold=0.5` — which is what a duplicated constant does even inside one module.
(= (stale-threshold) 0.3)
;; How many beliefs one ambient pass may actually REFRESH. Ambient work is background work: it must not
;; become a barrier on the cognitive cycle. Counted against SUCCESSFUL refreshes, not against candidates
;; examined — see `revalidate-worth-trying?`.
(= (revalidate-budget) 16)
;; How many classes one base-rate pass may touch, per universe.
(= (base-rate-limit) 64)

;; ── staleness ────────────────────────────────────────────────────────────────────────────────────
;; The decay LAW and its rate are NOT here — they are `DecayedConfidence` / `BeliefDecayRate` in
;; `Core/lib/pln/decay.metta`, shared with everything else that ages a truth value. This file only
;; decides what to DO about the number that law produces.
(= (belief-stale? $c0 $t0 $t)
   (< (DecayedConfidence $c0 $t0 $t (BeliefDecayRate)) (stale-threshold)))

;; ── priority ─────────────────────────────────────────────────────────────────────────────────────
;; HOW URGENT re-validating this belief is: how far it has fallen BELOW the threshold. A belief that has
;; decayed to 0.01 is more urgent than one that just crossed at 0.29, and the ambient budget should be
;; spent accordingly.
;;
;; Before this the budget was spent on `Iterators.take(stale, 16)` over a KEY-SORTED list — i.e. the
;; agent re-validated alphabetically. That is an attention-allocation policy, arrived at by accident,
;; and it starved: a stale key whose evidence has all disappeared can never be refreshed, so it stayed
;; in the candidate list forever and consumed one of the 16 slots on every single pass. Sixteen such
;; keys sorting early and NO later belief is ever re-validated again, permanently.
(= (staleness-priority $c0 $t0 $t)
   (- (stale-threshold) (DecayedConfidence $c0 $t0 $t (BeliefDecayRate))))

;; A belief is worth SPENDING BUDGET on only if evidence still anchors it. With no surviving evidence
;; `revalidate-one!` declines — the belief is left to keep decaying rather than propped up, which is the
;; honest outcome for a symbol nothing supports any more and is what keeps decay meaningful.
(= (revalidate-worth-trying? $h $ev-space $key)
   (> (wm-evidence-count $h $ev-space $key) 0))

;; ── the candidate set ────────────────────────────────────────────────────────────────────────────
;; Emit `(cand key priority)` for every STALE belief — DETECTION, deliberately unfiltered. "This belief
;; has decayed and nothing can rescue it" is a fact an operator wants reported, so the anchoring test is
;; NOT applied here; it belongs to spending, not to detecting. The caller sorts by priority and spends
;; its budget on successes only, which is what stops unrescuable keys from occupying slots forever.
;; Sorting is mechanical; the ORDER RELATION is `staleness-priority`, and it is here.
(= (stale-candidate $t (row $key $c0 $t0))
   (if (belief-stale? $c0 $t0 $t)
       (cand $key (staleness-priority $c0 $t0 $t))
       (empty)))

;; NOTE the `let $rows` — `(superpose (wm-belief-rows …))` superposes over the UNEVALUATED call
;; expression (its 3 tokens), not over the returned rows. Bind first, then superpose over the value.
;; (Same trap as base_rate_refresh.metta:35-37; observed here as `(stale-candidate … wm-belief-rows)`.)
(= (stale-candidates $h $space $t)
   (let $rows (wm-belief-rows $h $space)
      (collapse (let $row (superpose $rows) (stale-candidate $t $row)))))

;; ── re-validation ────────────────────────────────────────────────────────────────────────────────
;; Refresh ONE belief's confidence from the evidence that currently anchors it, and reset its decay
;; clock to $t. STRENGTH IS PRESERVED — re-validation refreshes how confident we are given current
;; evidence, it does not invent what we believe.
;;
;; The confidence comes from `EvidenceConfidence` (= the canonical `Truth_w2c`, k = 1) in
;; Core/lib/pln/decay.metta. It used to be `c_new = n / (n + 1)` in Julia, under a comment that named
;; the canonical map it was transcribing — while `EvidenceConfidence` itself sat in the library with
;; zero callers. Using the canonical map is what puts a revalidated confidence on the SAME evidence
;; scale as every other truth value in the system, so revision stays coherent.
(= (revalidate-one! $h $space $ev-space $t $key)
   (if (not (revalidate-worth-trying? $h $ev-space $key))
       unsupported
       (let $n (wm-evidence-count $h $ev-space $key)
          (let $s (wm-belief-strength $h $space $key)
             (case $s
               ((no-belief  absent)
                ;; `let $_` sequences the write before the report — there is no `seq` primitive; binding
                ;; the unit result of the write is the idiom (and forces it to actually happen).
                ($str (let $c (EvidenceConfidence $n)
                         (let $_ (wm-put-belief! $h $space $key $str $c $t)
                              (revalidated $key $c))))))))))
