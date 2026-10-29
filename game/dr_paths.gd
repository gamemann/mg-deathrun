extends RefCounted

## Where this game's own files are, wherever this copy of it lives. A delivered pack mounts
## under `res://dot_cloud/<id>/<version>/`, so own-file paths go through [method rebase]; built
## in it returns its argument. Holders of these paths are `static var`, never `const`.

const _SELF := preload("dr_paths.gd")


## This game's content root: `res://` built in, the mount prefix delivered.
static func root() -> String:
	# Through [Resource], because a const-preloaded script is typed as its own class and
	# `resource_path` is not reachable on that — "Cannot find member resource_path in
	# base res://…". The cast costs nothing and is the only spelling that compiles.
	var here: Resource = _SELF
	return here.resource_path.get_base_dir().get_base_dir()


## Moves one `res://` path onto [method root]. Anything else comes back untouched, and format
## specifiers survive: only the prefix is replaced.
static func rebase(path: String) -> String:
	return rebase_onto(path, root())


## [method rebase], against a root given rather than discovered, so a suite can test the
## mounted case from a build (built in, every property of rebase is a tautology).
static func rebase_onto(path: String, here: String) -> String:
	if not path.begins_with("res://"):
		return path

	# Idempotent: the publisher already rewrote `res://` strings inside scenes and resources
	# onto the mount prefix, and rebasing those again doubles it. See docs/comment-notes.md.
	if path.begins_with(here):
		return path

	return here.path_join(path.substr(6))
