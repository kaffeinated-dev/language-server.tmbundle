// Converts responses of language servers (mate --lsp, JSON on the standard
// input) for TextMate:
//
//     osascript -l JavaScript language_server.js completions BEFORE TYPED
//         Suggestions for "$DIALOG" popup (a property list) completing the
//         word TYPED at the end of BEFORE (the line before the caret): the
//         label shown (display), the word (match), and what follows the word,
//         inserted as a snippet (insert), such as its arguments.
//
//     osascript -l JavaScript language_server.js hover
//         The hover information as HTML for "$DIALOG" tooltip, or nothing.
//
//     osascript -l JavaScript language_server.js locations ROOT
//         Locations (of a definition) as items for "$DIALOG" menu, whose value
//         is LINE:COLUMN, a tab, and the file; paths relative to ROOT.
//
//     osascript -l JavaScript language_server.js references ROOT TITLE
//         The locations as a page for TextMate’s HTML window: by file (relative
//         to ROOT), their lines linked to open them. Nothing without any.
//
//     osascript -l JavaScript language_server.js actions
//         The titles of code actions, as items for "$DIALOG" menu (their value
//         is their index), or nothing.
//
//     osascript -l JavaScript language_server.js action INDEX
//         What running the action takes: “edit” and the params of
//         workspace/applyEdit (and a command to run after, if any), “command”
//         and those of workspace/executeCommand, or “resolve” and the action,
//         to get its edit with codeAction/resolve.
//
//     osascript -l JavaScript language_server.js resolved
//         What running a resolved action takes, as for action.
//
//     osascript -l JavaScript language_server.js placeholder LINE WORD
//         The name that renaming the symbol at the caret replaces (the answer
//         of textDocument/prepareRename), on LINE, the caret’s line. WORD,
//         without an answer. An error when it can’t be renamed.
//
//     osascript -l JavaScript language_server.js rename LABEL
//         The params of workspace/applyEdit for the edit of a rename.
//
//     osascript -l JavaScript language_server.js applied
//         Nothing when an edit was applied; an error with the reason otherwise.
//
//     osascript -l JavaScript language_server.js symbols ROOT
//         Symbols (of workspace/symbol) as items for "$DIALOG" menu, whose value
//         is LINE:COLUMN, a tab, and the file.
//
// An error response is an error, with the server’s message.

ObjC.import('Foundation');

function run(argv) {
	const input = $.NSString.alloc.initWithDataEncoding($.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile, $.NSUTF8StringEncoding).js;
	const response = JSON.parse(input);
	if (response.error && argv[0] === 'placeholder') // Servers without prepareRename
		return argv[2];
	if (response.error && response.error.code === -32601 && /^method not found/i.test(response.error.message))
		throw new Error('The language server of this document can’t do this.');
	if (response.error)
		throw new Error(response.error.message.split('\n')[0]);
	switch (argv[0]) {
		case 'hover':      return hover(response.result);
		case 'locations':  return locations(response.result, argv[1]);
		case 'references': return references(response.result, argv[1], argv[2]);
		case 'actions':    return actions(response.result);
		case 'action':     return action((response.result || [])[Number(argv[1])]);
		case 'resolved':   return action(response.result, true);
		case 'placeholder': return placeholder(response.result, argv[1], argv[2]);
		case 'rename':     return rename(response.result, argv[1]);
		case 'symbols':    return symbols(response.result, argv[1]);
		case 'applied':    return applied(response.result);
		default:           return completions(response.result, argv[1] || '', argv[2] || '');
	}
}

function plist(value) {
	const data = $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError($(value), $.NSPropertyListXMLFormat_v1_0, 0, null);
	return $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js;
}

function pathOf(uri) {
	return $.NSURL.URLWithString(uri).path.js;
}

function relative(path, root) {
	return root && path.startsWith(root + '/') ? path.slice(root.length + 1) : path;
}

// The lines of a file, read once.
const files = new Map();
function linesOf(path) {
	if (!files.has(path)) {
		const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
		files.set(path, text.isNil() ? [] : text.js.split('\n'));
	}
	return files.get(path);
}

// Locations (Location or LocationLink) as a path and start, once each: servers
// can report a location twice.
function places(result) {
	const seen = new Set();
	return [].concat(result || []).map(location => location && location.targetUri
		? { uri: location.targetUri, range: location.targetSelectionRange || location.targetRange }
		: location
	).filter(location => location && location.uri && location.range).map(location => ({
		path: pathOf(location.uri), start: location.range.start,
	})).filter(place => {
		const key = `${place.path}:${place.start.line}:${place.start.character}`;
		return !seen.has(key) && seen.add(key);
	});
}

const escapeHTML = text => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function locations(result, root) {
	const items = places(result).map(({ path, start }) => ({
		title: `${relative(path, root)}:${start.line + 1} — ${(linesOf(path)[start.line] || '').trim()}`,
		value: `${start.line + 1}:${start.character + 1}\t${path}`,
	}));
	return items.length ? plist(items) : '';
}

function references(result, root, title) {
	const found = places(result);
	if (found.length === 0)
		return '';

	const byFile = new Map();
	for (const { path, start } of found) {
		if (!byFile.has(path))
			byFile.set(path, []);
		byFile.get(path).push(start);
	}

	const sections = [...byFile.keys()].sort((a, b) => relative(a, root).localeCompare(relative(b, root))).map(path => {
		const lines = linesOf(path);
		const items = byFile.get(path).sort((a, b) => a.line - b.line || a.character - b.character).map(start => {
			const url = `txmt://open?url=file://${encodeURI(path).replace(/#/g, '%23').replace(/&/g, '%26')}&line=${start.line + 1}&column=${start.character + 1}`;
			const line = (lines[start.line] || '').trim();
			return `<li><a href="${escapeHTML(url)}"><span class="line">${start.line + 1}</span> <code>${escapeHTML(line)}</code></a></li>`;
		});
		return `<h2>${escapeHTML(relative(path, root))}</h2>\n<ul>\n${items.join('\n')}\n</ul>`;
	});

	const count = `${found.length} reference${found.length === 1 ? '' : 's'} in ${byFile.size} file${byFile.size === 1 ? '' : 's'}`;
	return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>${escapeHTML(title)}</title>
<style>
	:root { color-scheme: light dark; --muted: #6e6e6e; --link: #1f5fd1; --hover: rgba(127, 127, 127, .15); }
	@media (prefers-color-scheme: dark) { :root { --muted: #9a9a9a; --link: #7aa7ff; } }
	body { font: 13px -apple-system, sans-serif; margin: 1.5em; }
	h1 { font-size: 1.3em; margin: 0 0 .2em; }
	.meta { color: var(--muted); margin: 0 0 1em; }
	h2 { font-size: 1em; margin: 1.2em 0 .3em; }
	ul { list-style: none; margin: 0; padding: 0; }
	li a { display: block; padding: .15em .4em; border-radius: 4px; color: inherit; text-decoration: none; }
	li a:hover { background: var(--hover); }
	.line { display: inline-block; min-width: 3em; text-align: right; color: var(--muted); font: 12px ui-monospace, Menlo, monospace; }
	code { font: 12px ui-monospace, Menlo, monospace; }
</style>
</head>
<body>
<h1>${escapeHTML(title)}</h1>
<p class="meta">${count}</p>
${sections.join('\n')}
</body>
</html>
`;
}

function actions(result) {
	const items = (result || []).map((action, index) => ({ title: action && action.title, value: String(index) })).filter(item => item.title);
	return items.length ? plist(items) : '';
}

function action(chosen, resolved) {
	if (!chosen)
		throw new Error('There is no such action.');
	// A Command has a string command; a CodeAction may have an edit, a command,
	// or both, or data to resolve them with.
	if (!resolved && !chosen.edit && chosen.data !== undefined && typeof chosen.command !== 'string')
		return 'resolve\n' + JSON.stringify(chosen);
	if (typeof chosen.command === 'string')
		return 'command\n' + JSON.stringify({ command: chosen.command, arguments: chosen.arguments || [] });
	if (chosen.edit)
		return 'edit\n' + JSON.stringify({ label: chosen.title, edit: chosen.edit }) + (chosen.command ? '\n' + JSON.stringify({ command: chosen.command.command, arguments: chosen.command.arguments || [] }) : '');
	if (chosen.command)
		return 'command\n' + JSON.stringify({ command: chosen.command.command, arguments: chosen.command.arguments || [] });
	throw new Error('The action has nothing to do.');
}

function placeholder(result, line, word) {
	if (!result)
		throw new Error('This can’t be renamed.');
	if (typeof result.placeholder === 'string')
		return result.placeholder;
	const range = result.range || result;
	if (range.start && range.end && range.start.line === range.end.line)
		return line.slice(range.start.character, range.end.character) || word;
	return word;
}

function rename(result, label) {
	if (!result)
		throw new Error('This can’t be renamed.');
	return JSON.stringify({ label: label, edit: result });
}

function symbols(result, root) {
	const kinds = { 2: 'module', 5: 'class', 6: 'method', 7: 'property', 8: 'field', 9: 'constructor', 10: 'enum', 11: 'interface', 12: 'function', 13: 'variable', 14: 'constant', 22: 'struct', 23: 'event', 24: 'operator', 26: 'type' };
	const seen = new Set();
	const items = (result || []).filter(symbol => symbol && symbol.location && symbol.location.range).map(symbol => {
		const path = pathOf(symbol.location.uri), start = symbol.location.range.start;
		return {
			title: `${symbol.name} — ${relative(path, root)}:${start.line + 1}${kinds[symbol.kind] ? `  (${kinds[symbol.kind]})` : ''}`,
			value: `${start.line + 1}:${start.character + 1}\t${path}`,
		};
	}).filter(item => !seen.has(item.title + item.value) && seen.add(item.title + item.value));
	return items.length ? plist(items) : '';
}

// The word of an item is its name (such as “map” for “map(enumerable, fun)”),
// or for an item that edits the line, the word the edit makes from where the
// typed word starts (such as “Greeter” for “Sample::Greeter” replacing
// “Sample::Gre”). What follows the word in the item’s text is inserted as a
// snippet.
function completions(result, before, typed) {
	const items = (result && result.items ? result.items : result || []).filter(item => item && typeof item.label === 'string');
	items.sort((a, b) => (a.sortText || a.label) < (b.sortText || b.label) ? -1 : (a.sortText || a.label) > (b.sortText || b.label) ? 1 : 0);

	const wordStart = before.length - typed.length;
	const suggestions = [];
	for (const item of items) {
		const snippet = item.insertTextFormat === 2;
		let name = (item.filterText || item.label).split(/[( ]/)[0];
		let text = item.textEdit ? item.textEdit.newText : (item.insertText || item.label);

		const range = item.textEdit && (item.textEdit.range || item.textEdit.insert);
		if (range && range.start) {
			const start = range.start.character;
			if (start > before.length || !(before.slice(0, start) + text).startsWith(before.slice(0, wordStart)))
				continue;
			text = (before.slice(0, start) + text).slice(wordStart);
			name = text.split(snippet ? /[( $]/ : /[( ]/)[0];
		}
		if (!name)
			continue;

		const suggestion = { display: item.label, match: name };
		if (text.startsWith(name) && text.length > name.length)
			suggestion.insert = snippet ? text.slice(name.length) : text.slice(name.length).replace(/[$`\\]/g, '\\$&'); // Plain text, inserted as a snippet
		suggestions.push(suggestion);
	}

	return suggestions.length ? plist(suggestions) : '';
}

// Markdown (as servers send it) as simple HTML: code blocks, inline code,
// emphasis, links (as their text), and paragraphs. Long documentation ends
// after a few paragraphs.
function hover(result) {
	if (!result || !result.contents)
		return '';

	const parts = [].concat(result.contents).map(part => typeof part === 'string' ? part : part.language ? '```\n' + part.value + '\n```' : part.value);
	const escape = text => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
	const inline = text => escape(text)
		.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
		.replace(/`([^`]+)`/g, '<code>$1</code>')
		.replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>')
		.replace(/(^|[^\w*])[*_]([^*_]+)[*_](?![\w*])/g, '$1<i>$2</i>');

	const paragraph = text => {
		if (text.split('\n').every(line => /^(    |\t)/.test(line)))
			return `<pre>${escape(text.replace(/^(    |\t)/gm, ''))}</pre>`;
		const heading = text.match(/^#{1,6}\s+(.*)$/);
		return heading ? `<p><b>${inline(heading[1])}</b></p>` : `<p>${inline(text.trim())}</p>`;
	};

	const blocks = parts.join('\n\n').split(/(```[^\n]*\n[\s\S]*?\n```)/);
	const html = [];
	let length = 0;
	for (const block of blocks) {
		const code = block.match(/^```[^\n]*\n([\s\S]*?)\n```$/);
		const pieces = code ? [`<pre>${escape(code[1])}</pre>`] : block.split(/\n\s*\n/).filter(p => p.trim()).map(paragraph);
		for (const piece of pieces) {
			if (length > 1200) {
				html.push('<p class="more">…</p>');
				return page(html);
			}
			html.push(piece);
			length += piece.length;
		}
	}
	return page(html);
}

function page(html) {
	return '<style>body { font: 12px -apple-system, sans-serif; max-width: 42em; } p { margin: .4em 0; } ' +
		'pre, code { font: 11px ui-monospace, Menlo, monospace; } pre { margin: .4em 0; white-space: pre-wrap; } .more { color: gray; }</style>' +
		html.join('');
}

function applied(result) {
	if (result && result.applied === false)
		throw new Error(result.failureReason || 'The edit was not applied.');
	return '';
}
