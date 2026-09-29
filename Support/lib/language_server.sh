# Commands that ask the language server of a document (through TextMate, with
# mate --lsp) about the code at the caret, for any language with one.
#
# Other bundles can source this file, or run Support/bin/completions.

LANGUAGE_SERVER_SUPPORT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Tool tips are printed to stderr, as the standard output of HTML commands goes
# to their window.
language_server_exit_tool_tip () { printf '%s' "$1" >&2; exit 206; }
language_server_exit_discard  () { exit 200; }

# The folder that paths are shown relative to.
language_server_project () {
	echo "${TM_PROJECT_DIRECTORY:-${TM_DIRECTORY:-${TMPDIR:-/tmp}}}"
}

# The caret (line:column, both from 1, the column in bytes as TextMate counts),
# or with symbol, the last character of the word the caret is right after, as
# servers find nothing after a word.
language_server_position () { # [symbol]
	local index=${TM_LINE_INDEX:-0} line=${TM_CURRENT_LINE:-} before after
	if [[ "${1:-}" == symbol ]] && (( index > 0 )); then
		before=$(printf '%s' "$line" | head -c "$index" | tail -c 1)
		after=$(printf '%s' "$line" | tail -c +$(( index + 1 )) | head -c 1)
		[[ "$before" =~ [[:alnum:]_?!] && ! "$after" =~ [[:alnum:]_?!] ]] && index=$(( index - 1 ))
	fi
	echo "${TM_LINE_NUMBER:-1}:$(( index + 1 ))"
}

# Send a request about the document to its language server and print the
# response (JSON). The position is the caret’s, unless given (or none).
language_server_request () { # method, [params (JSON)], [position]
	local args=(--lsp "$1") position=${3:-$(language_server_position)}
	[[ "$position" != none ]] && args+=(--line "$position")
	[[ -n "${2:-}" ]] && args+=(--lsp-params "$2")
	"$TM_MATE" "${args[@]}" 2>&1 ||
		language_server_exit_tool_tip "This needs TextMate 2.0.23+kaffeinated.6 or later, with the language server client."
}

# Convert a response (the standard input) with language_server.js, showing an
# error of the server in a tool tip.
language_server_convert () { # conversion, arguments…
	local output
	output=$(osascript -l JavaScript "$LANGUAGE_SERVER_SUPPORT/lib/language_server.js" "$@" 2>&1) ||
		language_server_exit_tool_tip "$(printf '%s' "$output" | sed -E 's/.*execution error: (Error: )*//; s/ \(-?[0-9]+\)$//')"
	printf '%s' "$output"
}

# A string as JSON.
language_server_json_string () {
	local s=${1//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\t'/\\t}
	printf '"%s"' "${s//$'\n'/\\n}"
}

# Ask for a string: title, prompt, default value, button title. Prints the
# string; returns 1 when cancelled.
language_server_request_string () {
	local model token
	model="{ title = $(language_server_json_string "$1"); prompt = $(language_server_json_string "$2"); string = $(language_server_json_string "$3"); button1 = $(language_server_json_string "${4:-OK}"); button2 = Cancel; }"
	token=$("$DIALOG" nib --load "$TM_SUPPORT_PATH/nibs/RequestString.nib" --center --model "$model") || return 1
	"$DIALOG" nib --modal --wait "$token" --dispose "$token" | /usr/bin/plutil -extract eventInfo.returnArgument raw -o - - 2>/dev/null
}

# The value of the item chosen from a menu ($DIALOG menu), or nothing.
language_server_menu () { "$DIALOG" menu --items "$1" | /usr/bin/plutil -extract value raw -o - - 2>/dev/null; }

# Open the location (LINE:COLUMN, a tab, and the file) of the only item of a
# menu, or of the item chosen.
language_server_open () { # menu items
	local choice
	if [[ $(grep -c '<dict>' <<< "$1") -eq 1 ]]; then
		choice=$(/usr/bin/plutil -extract 0.value raw -o - - <<< "$1")
	else
		choice=$(language_server_menu "$1")
	fi
	[[ -n "$choice" ]] || language_server_exit_discard
	"$TM_MATE" -l "${choice%%$'\t'*}" "${choice#*$'\t'}" >/dev/null 2>&1
	exit 200
}

# ============
# = Commands =
# ============

# The text before the caret, and the word being typed at its end.
language_server_typed () {
	LANGUAGE_SERVER_BEFORE_CARET="" LANGUAGE_SERVER_TYPED=""
	if (( ${TM_LINE_INDEX:-0} > 0 )); then
		LANGUAGE_SERVER_BEFORE_CARET=$(printf '%s' "${TM_CURRENT_LINE:-}" | head -c "$TM_LINE_INDEX")
		LANGUAGE_SERVER_TYPED=$(printf '%s' "$LANGUAGE_SERVER_BEFORE_CARET" | sed -E 's/.*[^[:alnum:]_?!]//')
	fi
}

# The language server’s completions of the word at the caret, as suggestions
# for "$DIALOG" popup (a property list), or nothing.
language_server_completions () {
	local response
	language_server_typed
	response=$(language_server_request textDocument/completion) || exit
	printf '%s' "$response" | language_server_convert completions "$LANGUAGE_SERVER_BEFORE_CARET" "$LANGUAGE_SERVER_TYPED"
}

# Show the completions in a popup. Choosing one completes it, with
# placeholders for its arguments.
language_server_complete () {
	local suggestions
	language_server_typed
	suggestions=$(language_server_completions) || exit
	[[ -n "$suggestions" ]] || language_server_exit_tool_tip "No completions."
	"$DIALOG" popup --suggestions "$suggestions" --alreadyTyped "$LANGUAGE_SERVER_TYPED" --additionalWordCharacters '?!'
	exit 200
}

# Show what the language server knows about the code at the caret (its type
# and documentation) in a tool tip.
language_server_hover () {
	local response html
	response=$(language_server_request textDocument/hover "" "$(language_server_position symbol)") || exit
	html=$(printf '%s' "$response" | language_server_convert hover) || exit
	[[ -n "$html" ]] || language_server_exit_tool_tip "No information about this."
	"$DIALOG" tooltip --html "$html"
	exit 200
}

# Open the definition of the symbol at the caret, or choose one of several.
language_server_go_to_definition () {
	local response items
	response=$(language_server_request textDocument/definition "" "$(language_server_position symbol)") || exit
	items=$(printf '%s' "$response" | language_server_convert locations "$(language_server_project)") || exit
	[[ -n "$items" ]] || language_server_exit_tool_tip "No definition found."
	language_server_open "$items"
}

# Show the references to the symbol at the caret (with its definition) in an
# HTML window, linked to open them.
language_server_find_references () {
	local response html
	response=$(language_server_request textDocument/references '{"context":{"includeDeclaration":true}}' "$(language_server_position symbol)") || exit
	html=$(printf '%s' "$response" | language_server_convert references "$(language_server_project)" "References to ${TM_CURRENT_WORD:-the symbol}") || exit
	[[ -n "$html" ]] || language_server_exit_tool_tip "No references found. Language servers find references once they have indexed the project."
	printf '%s' "$html"
	exit 0
}

# The selection as the range of a request (JSON), as the server counts: exact
# on the caret’s line, and by lines over several (whole ones, for those not
# selected from their start). Fails without one selection.
language_server_selection_range () {
	local selection=${TM_SELECTION:-} from to from_line from_column to_line to_column
	[[ "$selection" =~ ^([0-9]+):([0-9]+)-([0-9]+):([0-9]+)$ ]] || return 1
	from_line=${BASH_REMATCH[1]} from_column=${BASH_REMATCH[2]} to_line=${BASH_REMATCH[3]} to_column=${BASH_REMATCH[4]}
	if (( to_line < from_line || (to_line == from_line && to_column < from_column) )); then
		from_line=${BASH_REMATCH[3]} from_column=${BASH_REMATCH[4]} to_line=${BASH_REMATCH[1]} to_column=${BASH_REMATCH[2]}
	fi

	if (( from_line == to_line )); then
		(( from_line == ${TM_LINE_NUMBER:-0} )) || return 1
		from=$(language_server_utf16_length "$(( from_column - 1 ))") to=$(language_server_utf16_length "$(( to_column - 1 ))")
		printf '{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}' $(( from_line - 1 )) "$from" $(( to_line - 1 )) "$to"
	else
		printf '{"start":{"line":%d,"character":0},"end":{"line":%d,"character":0}}' $(( from_line - 1 )) $(( to_column > 1 ? to_line : to_line - 1 ))
	fi
}

# The length (in UTF-16 code units) of the first bytes of the caret’s line.
language_server_utf16_length () { # bytes
	(( $1 > 0 )) || { echo 0; return; }
	echo $(( $(printf '%s' "${TM_CURRENT_LINE:-}" | head -c "$1" | iconv -f UTF-8 -t UTF-16LE | wc -c) / 2 ))
}

# Show the language server’s code actions for the selection or the line of the
# caret (quick fixes for its warnings, and refactorings) in a menu, and run the
# one chosen.
language_server_quick_fix () {
	local tmp range params="" what=line items choice kind command
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/textmate-language-server.XXXXXX") || exit 1
	trap 'rm -rf "$tmp"' EXIT

	range=$(language_server_selection_range) && params="{\"range\":$range}" what=selection
	language_server_request textDocument/codeAction "$params" > "$tmp/actions" || exit
	items=$(language_server_convert actions < "$tmp/actions") || exit
	[[ -n "$items" ]] || language_server_exit_tool_tip "No quick fixes for this $what."
	choice=$(language_server_menu "$items")
	[[ -n "$choice" ]] || language_server_exit_discard

	language_server_convert action "$choice" < "$tmp/actions" > "$tmp/action" || exit
	{ read -r kind; read -r params; read -r command; } < "$tmp/action"
	if [[ "$kind" == resolve ]]; then
		language_server_request codeAction/resolve "$params" > "$tmp/resolved" || exit
		language_server_convert resolved < "$tmp/resolved" > "$tmp/action" || exit
		{ read -r kind; read -r params; read -r command; } < "$tmp/action"
	fi

	if [[ "$kind" == edit ]]; then
		language_server_apply "$params"
		[[ -n "$command" ]] && params=$command kind=command
	fi
	if [[ "$kind" == command ]]; then
		language_server_request workspace/executeCommand "$params" > "$tmp/result" || exit
		language_server_convert applied < "$tmp/result" > /dev/null || exit
	fi
	exit 200
}

# Rename the symbol at the caret everywhere, as the language server edits it:
# the name it replaces (such as Module::Class) is asked for first.
language_server_rename () {
	local position response current name params
	position=$(language_server_position symbol)
	response=$(language_server_request textDocument/prepareRename "" "$position") || exit
	current=$(printf '%s' "$response" | language_server_convert placeholder "${TM_CURRENT_LINE:-}" "${TM_CURRENT_WORD:-}") || exit

	name=$(language_server_request_string "Rename Symbol" "New name for “${current}”:" "$current" "Rename") || language_server_exit_discard
	[[ -n "$name" && "$name" != "$current" ]] || language_server_exit_discard

	response=$(language_server_request textDocument/rename "{\"newName\":$(language_server_json_string "$name")}" "$position") || exit
	params=$(printf '%s' "$response" | language_server_convert rename "Rename to $name") || exit
	language_server_apply "$params"
	exit 200
}

# Apply an edit (the params of workspace/applyEdit) as TextMate applies the
# edits of language servers: undoable in open documents, and saved in others.
language_server_apply () { # params
	local result
	result=$(language_server_request workspace/applyEdit "$1") || exit
	printf '%s' "$result" | language_server_convert applied > /dev/null || exit
}

# Format the document with its language server: its edits are applied to the
# document (in place, so they can be undone), with the tab size and soft tabs
# of the document as options. Returns 0 when the document changed, 1 when
# there was nothing to change, and 2 (with the reason on standard error) when
# the document has no language server, or one that does not format
# documents. Exits, showing why in a tool tip, when it could not be formatted.
language_server_format () {
	local options response output
	options=$(printf '{"options":{"tabSize":%d,"insertSpaces":%s}}' "${TM_TAB_SIZE:-4}" "$([[ "${TM_SOFT_TABS:-}" == YES ]] && echo true || echo false)")
	response=$(language_server_request textDocument/formatting "$options" none) || exit
	output=$(printf '%s' "$response" | language_server_convert formatting "${TM_FILEPATH:-}") || exit
	case "${output%%$'\n'*}" in
		edit)        language_server_apply "${output#*$'\n'}"; return 0 ;;
		unsupported) printf '%s\n' "${output#*$'\n'}" >&2; return 2 ;;
		*)           return 1 ;;
	esac
}

# Find symbols of the project by name (the language server’s workspace/symbol)
# and open the one chosen.
language_server_go_to_symbol () {
	local query response items
	query=$(language_server_request_string "Go to Symbol in Project" "Symbols named:" "${TM_SELECTED_TEXT:-${TM_CURRENT_WORD:-}}" "Find") || language_server_exit_discard
	[[ -n "$query" ]] || language_server_exit_discard

	response=$(language_server_request workspace/symbol "{\"query\":$(language_server_json_string "$query")}") || exit
	items=$(printf '%s' "$response" | language_server_convert symbols "$(language_server_project)") || exit
	[[ -n "$items" ]] || language_server_exit_tool_tip "No symbols named “${query}”. Language servers find symbols once they have indexed the project (and some only by their full name, such as Module::Class)."
	language_server_open "$items"
}
