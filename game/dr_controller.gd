extends DotFpsController

## The first-person controller, with the two hooks a course needs inside the tick.
## They must run inside it so the predictor's replayed ticks pose the obstacles too.

## `func(tick: int) -> void`: put the world where it is on [param tick], before the motor runs.
var before_fn: Callable = Callable()

## `func(tick: int, state: DotFpsState) -> void`: what the world does to the player after
## the motor has moved them — the carry of whatever they are standing on.
var after_fn: Callable = Callable()


func _on_pre_simulate(tick: int, _delta: float) -> void:
	if before_fn.is_valid():
		before_fn.call(tick)


func _on_post_simulate(tick: int, _delta: float) -> void:
	if after_fn.is_valid():
		after_fn.call(tick, state)
