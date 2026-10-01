extends Node

## Autoload. Central bus for "risk" events - things the player does (or
## suffers) that scoring, nitro, time stop, UI and audio all care about.
## Publishers emit here instead of calling those systems directly; each
## system connects to the signals it needs. Carries no state and no logic.
##
## Must load BEFORE RunRewards (which connects in its own _ready) - keep the
## autoload order in project.godot.
##
## `speed_pct` everywhere is player speed / CrashSystem.REFERENCE_MAX_SPEED
## (the same normalisation the scoring formula already used).

## Near-miss closeness, by the smallest side gap reached during the pass
## (see crash_system.gd's *_MARGIN_W). Values are ordered - higher = closer.
enum NearMissTier { CLOSE, HAIRLINE, IMPOSSIBLE }

## A traffic car was passed within near-miss range (once per car, per tier).
signal near_miss(speed_pct: float, tier: NearMissTier)

## A traffic car that was ahead of the player is now behind (once per car,
## any lane, regardless of how close it was).
signal overtake(speed_pct: float)

## The player's car hit something - breaks the combo.
signal collision

## Emitted by DriftScorer (MAIN/gameplay/drift_scorer.gd) every tick of a live
## drift session: `points` is the session's running total (not yet in the
## pile), `duration_mult` the session's duration multiplier, `prox_mult` the
## proximity bonus right now (1 = none; `prox_reason` names it), `angle_deg`
## the current slip angle.
signal drift_updated(points: float, duration_mult: float, prox_mult: float, prox_reason: String, angle_deg: float)
## A drift session ended and `points` landed in the pile (0 = too small to
## count). `reason`: "DRIFT" (straightened out), "SPUN OUT", "HIT", or
## "LOST" (a crash / the run ended - nothing landed).
signal drift_ended(points: int, reason: String)

## Emitted by HighSpeedScorer (MAIN/gameplay/high_speed_scorer.gd) every tick
## the player holds the high-speed threshold: `seconds` held so far this
## session. `high_speed_ended` fires once when they drop under it.
signal high_speed_updated(seconds: float)
signal high_speed_ended

## Emitted by SlipstreamScorer (MAIN/gameplay/slipstream_scorer.gd) every tick
## the player is tucked in behind a traffic car: `charge` 0..1 (how much boost
## is stored), `seconds` drafted so far this session. `slipstream_ended` fires
## once when they leave the pocket.
signal slipstream_updated(charge: float, seconds: float)
signal slipstream_ended
## The player swung out of a charged slipstream - `strength` 0..1 is the charge
## they left with. BoostBurst (MAIN/misc/boost_burst.gd) turns it into speed.
signal slipstream_boost(strength: float)

## Emitted by RunRewards (which owns the pile) for UI/audio to react to.
## The pile changed: an event added `added` points (0 = only the multiplier
## was reset by a collision). `reason` is the display name of what scored
## ("NEAR MISS", "HAIRLINE!", "IMPOSSIBLE!!", "OVERTAKE", later "SLIPSTREAM"...) or
## "COMBO BROKEN" for a reset.
signal pile_updated(pile: float, added: int, multiplier: float, streak: int, reason: String)
## The chain timer ran out (or a checkpoint/run end banked it): `amount`
## just moved into the score.
signal pile_banked(amount: int)
## A crash scattered the pile - `amount` was lost.
signal pile_lost(amount: int)
