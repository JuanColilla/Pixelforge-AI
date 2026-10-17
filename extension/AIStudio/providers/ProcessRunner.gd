extends RefCounted
## Runs a CLI without blocking the editor. Output is redirected to files inside the job folder
## and the process is polled, so a cancel or timeout can kill it.

const SEARCH_PATH := "$HOME/.local/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

var _pid := -1
var _cancelled := false


func run(
	host: Node,
	executable: String,
	arguments: PackedStringArray,
	work_dir: String,
	timeout_sec: float
) -> Dictionary:
	_cancelled = false
	var stdout_path := work_dir.path_join("stdout.txt")
	var stderr_path := work_dir.path_join("stderr.txt")
	var quoted := PackedStringArray()
	for argument in arguments:
		quoted.append(shell_quote(argument))
	# CLAUDECODE is unset so a Claude CLI child never thinks it is nested in another session.
	var script := (
		'export PATH="%s"; unset CLAUDECODE; cd %s && exec %s %s > %s 2> %s < /dev/null'
		% [
			SEARCH_PATH,
			shell_quote(work_dir),
			shell_quote(executable),
			" ".join(quoted),
			shell_quote(stdout_path),
			shell_quote(stderr_path),
		]
	)
	_pid = OS.create_process("/bin/sh", ["-c", script])
	if _pid <= 0:
		return {"error": "could not start %s" % executable}
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while OS.is_process_running(_pid):
		if _cancelled or Time.get_ticks_msec() > deadline:
			OS.kill(_pid)
			_pid = -1
			return {"error": "cancelled" if _cancelled else "timed out after %d s" % timeout_sec}
		await host.get_tree().create_timer(0.25).timeout
	var exit_code := OS.get_process_exit_code(_pid)
	_pid = -1
	return {
		"exit_code": exit_code,
		"stdout": _read(stdout_path),
		"stderr": _read(stderr_path),
	}


func cancel() -> void:
	_cancelled = true


func is_running() -> bool:
	return _pid > 0


static func shell_quote(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"


static func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
