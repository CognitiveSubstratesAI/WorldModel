;; WorldModel/lib/base_rate_refresh.metta — the ambient base-rate refresh, DRIVEN FROM MeTTa.
;;
;; Julia's role here is SUBSTRATE ACCESS ONLY, exposed as grounded atoms:
;;   (wm-universe    $h $space $head)          -> Int    how many (head _ _) atoms exist
;;   (wm-classes     $h $space $head)          -> (c1 c2 …)  the distinct classes, sorted
;;   (wm-class-count $h $space $head $class)   -> Int    |ext(class)|
;;   (wm-put-belief! $h $name $s $c $t)        -> ()     write (belief name s c t) into Srule
;; `$h` is a registry HANDLE token — the SpaceRegistry stays host-side and never crosses the ABI, the same
;; by-handle discipline OmegaClaw's tick loop uses. Only small tokens and numbers cross.
;;
;; Everything else — the iteration, the arithmetic, the decision to write or skip — is HERE, as atoms the
;; agent can inspect and MOSES/GEO-EVO can rewrite. The formulas themselves live one level down in
;; Core/lib/pln/base_rate.metta (BaseRateTv), which builds on the canonical Truth_w2c. Nothing re-derives
;; n/(n+1) in a host language: that duplication is what silently killed 2-hop deduction.

;; ── refresh one class ────────────────────────────────────────────────────────────────────────────
;; Compute the extensional base rate for $class and store it as that node's belief. `no-evidence` is
;; NOT written: absence must stay absence, so node_stv keeps reporting "unknown" and callers skip,
;; rather than a fabricated (0,0) poisoning PLN's `as > 0` consistency precondition.
;; DESTRUCTURE the tv here rather than using stv-strength/stv-confidence: those accessors match the
;; UPPERCASE `(STV $s $c)` shape (stv.metta), while the truth formulas — Truth_Deduction and BaseRateTv —
;; produce the LOWERCASE `(stv $s $c)`. Calling the accessor on the lowercase form silently fails to
;; reduce and marshals as 0.0, which wrote (0,0) beliefs. `case` matches the shape we actually receive.
(= (refresh-one-base-rate! $h $space $head $rule-space $t $u $class)
   (let $tv (BaseRateTv (wm-class-count $h $space $head $class) $u)
      (case $tv
        (((stv $s $c) (wm-put-belief! $h $rule-space $class $s $c $t))
         ($_other      skipped)))))

;; ── refresh every class in a universe ────────────────────────────────────────────────────────────
;; `$head` selects the universe: `entity` over Sent = perceived concepts; `action`/`goal` over Senv =
;; the agent's own action graph. An empty universe writes nothing.
;; `$limit` bounds how many classes one ambient pass touches — a query bound, so it is applied by the
;; grounded accessor (substrate concern), not by arithmetic here.
;; NOTE the `let $cls` — `(superpose (wm-classes …))` superposes over the UNEVALUATED call expression
;; (its 5 tokens: the head symbol and 4 args), not over the returned class list. Bind the result first,
;; then superpose over the value. (Symptom before: 5 `skipped` for 4 classes.)
(= (refresh-base-rates! $h $space $head $rule-space $t $limit)
   (let $u (wm-universe $h $space $head)
      (if (<= $u 0)
          ()
          (let $cls (wm-classes $h $space $head $limit)
             (collapse
                (let $class (superpose $cls)
                   (refresh-one-base-rate! $h $space $head $rule-space $t $u $class)))))))
