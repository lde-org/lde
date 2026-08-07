local ansi = require("ansi")

local usage = require("lde.commands.usage")

-- Scripts are emitted as-is except for the __DIR_FLAGS__/__FILE_FLAGS__
-- placeholders, which are filled from usage.lua so the flag lists can't drift
-- between the scripts, the help text, and the completion backend.

local bash = [==[
# lde shell completion for bash.
# Source it from ~/.bashrc:  eval "$(lde completion bash)"

_lde() {
	local cur prev
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD-1]}"

	local IFS=$'\n'

	# Options that take a directory/file value: complete those directly.
	case "$prev" in
		__DIR_FLAGS__)
			COMPREPLY=( $(compgen -d -- "$cur") )
			return 0
			;;
		__FILE_FLAGS__)
			COMPREPLY=( $(compgen -f -- "$cur") )
			return 0
			;;
	esac

	# Everything after `--` is positional.
	local w
	for w in "${COMP_WORDS[@]:1:COMP_CWORD-1}"; do
		if [ "$w" = "--" ]; then
			COMPREPLY=( $(compgen -f -- "$cur") )
			return 0
		fi
	done

	# Only fall back to file completion once past the command position.
	if [ "$COMP_CWORD" -le 1 ] || [[ "$cur" == -* ]]; then
		compopt +o default 2>/dev/null
	else
		compopt -o default 2>/dev/null
	fi

	COMPREPLY=( $(lde __complete "${COMP_WORDS[@]:1}" 2>/dev/null) )
}

complete -F _lde lde
]==]

local zsh = [==[
#compdef lde
# lde shell completion for zsh.
# Source it from ~/.zshrc:  eval "$(lde completion zsh)"

_lde() {
	local curcontext="$curcontext" state line
	local -a completions

	case "${words[CURRENT-1]}" in
		__DIR_FLAGS__)
			_files -/
			return
			;;
		__FILE_FLAGS__)
			_files
			return
			;;
	esac

	# Everything after `--` is positional.
	if (( ${words[(I)--]} )); then
		_files
		return
	fi

	completions=("${(@f)$(lde __complete ${words[2,-1]} 2>/dev/null)}")
	if (( ${#completions} )); then
		compadd -a completions
	else
		_files
	fi
}

compdef _lde lde
]==]

local fish = [==[
# lde shell completion for fish.
# Source it from config.fish:  lde completion fish | source

function __lde_complete
	set -l tokens (commandline -opc)
	set -l n (count $tokens)

	if test $n -ge 2
		# Options that take a directory/file value: complete those directly.
		switch $tokens[-1]
			case __DIR_FLAGS__
				__fish_complete_directories
				return
			case __FILE_FLAGS__
				__fish_complete_path
				return
		end
		# Everything after `--` is positional.
		if contains -- $tokens
			__fish_complete_path
			return
		end
	end

	set -l out (lde __complete $tokens[2..-1] 2>/dev/null)
	if test (count $out) -eq 0
		# No candidates: offer files once past the command position.
		if test $n -ge 2
			__fish_complete_path
		end
	else
		for c in $out
			echo $c
		end
	end
end

complete -c lde -f -a '(__lde_complete)'
]==]

---@type table<string, string>
local scripts = {
	bash = bash:gsub("__DIR_FLAGS__", table.concat(usage.dirFlags, "|")):gsub("__FILE_FLAGS__", table.concat(usage.fileFlags, "|")),
	zsh = zsh:gsub("__DIR_FLAGS__", table.concat(usage.dirFlags, "|")):gsub("__FILE_FLAGS__", table.concat(usage.fileFlags, "|")),
	fish = fish:gsub("__DIR_FLAGS__", table.concat(usage.dirFlags, " ")):gsub("__FILE_FLAGS__", table.concat(usage.fileFlags, " ")),
}

---@param args clap.Args
local function completion(args)
	local shell = args:pop()
	if not shell then
		ansi.printf("{red}Usage: lde completion <bash|zsh|fish>")
		os.exit(1)
	end

	local script = scripts[shell]
	if not script then
		ansi.printf("{red}Unknown shell: %s (supported: bash, zsh, fish)", shell)
		os.exit(1)
	end

	io.write(script)
end

return completion
