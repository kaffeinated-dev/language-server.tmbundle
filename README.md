# Language Server

Commands that ask the [language server](https://microsoft.github.io/language-server-protocol/) of a document about its code, for any language whose bundle starts one, such as Elixir ([Expert](https://github.com/expert-lsp/expert)) and Ruby ([ruby-lsp](https://shopify.github.io/ruby-lsp/)). They need the [kaffeinated-dev fork of TextMate](https://github.com/kaffeinated-dev/textmate), 2.0.23+kaffeinated.6 or later.

# Installation

Clone the bundle into TextMate’s bundles folder:

	git clone https://github.com/kaffeinated-dev/language-server.tmbundle.git ~/Library/Application\ Support/TextMate/Bundles/Language\ Server.tmbundle

# Commands

| Command | Key | What it does |
|---|---|---|
| Complete | ⌥⎋ | Shows the server’s completions of the word at the caret in a popup. Choosing one completes it, with placeholders for its arguments. |
| Documentation Tooltip | ⌃⌥H | Shows what the server knows about the code at the caret (its type and documentation) in a tool tip. |
| Go to Definition | ⌃⌘J | Opens the definition of the symbol at the caret, or a menu of them when there are several. |
| Find References | ⇧⌃⌘F | Lists the uses of the symbol at the caret (and its definition) in a window, by file, linked to open them. |
| Go to Symbol in Project | ⌥⌘T | Asks for a name and opens the class, module, function, or method of the project with it. |
| Quick Fix | ⌥↩ | Shows the server’s code actions for the selection or the line of the caret in a menu, such as fixes for its warnings, or Extract Variable and Extract Method, and makes the one chosen. |
| Rename Symbol | ⌃⌘E | Asks for a new name for the symbol at the caret and renames it everywhere. Edits in open documents can be undone; other files are saved. |

The commands are for documents with a running language server, whose scope has `attr.language-server`, so their keys do what they did before in other documents. In those documents they come before commands of language bundles with the same keys, as the attribute is the most specific part of the scope, unless those are also for `attr.language-server`, such as `source.elixir attr.language-server`: Elixir’s own Go to Definition and the Ruby on Rails bundle’s ⌥⎋ (which completes routes, and adds the completions of the server to them) come first this way.

Language servers find references and symbols once they have indexed the project, which can take a little while after they start. Some find symbols by their full names only: ruby-lsp finds `Sample::Greeter`, but not `Greeter`. ruby-lsp renames a class from its definition or its unqualified uses; from a use such as `Sample::Greeter`, it leaves the name of the definition as it is.

# Language servers

A bundle starts a language server for documents of its language with a `languageServer` setting in a preference for their scope:

	languageServer = {
		command    = '"$TM_BUNDLE_SUPPORT/bin/language-server"';
		languageId = 'ruby';
		rootFiles  = ( 'Gemfile', 'gems.rb' );
	};

TextMate starts the command (with the environment of bundle commands) in the closest folder of the document with one of the root files, keeps it up to date with the documents open there, and shows its diagnostics in the gutter. See `LSPClient.h` in the TextMate fork for the details.

# For other bundles

A command of another bundle can add the completions of the language server to its own: `require` this bundle in the command (name “Language Server”, UUID `2B7B90FA-78B7-4922-98C7-C025E4F932B4`), which sets `TM_LANGUAGE_SERVER_BUNDLE_SUPPORT`, and run

	"$TM_LANGUAGE_SERVER_BUNDLE_SUPPORT/bin/completions"

which prints them as suggestions for `"$DIALOG" popup` (a property list), or nothing. A command can format the document with its language server the same way:

	"$TM_LANGUAGE_SERVER_BUNDLE_SUPPORT/bin/format"

applies the server’s edits to the document, in place, so they can be undone. It exits 0 when the document changed, 1 when there was nothing to change, and 2 when the document has no language server, or one that does not format documents or is still starting (so the command can format it another way, or not when saving); with another status when it could not be formatted. The reason is on standard error. With TextMate 2.0.23+kaffeinated.8 or later, only the lines that change are replaced, so the caret and bookmarks stay where they are. The Ruby bundle formats with RuboCop this way, through ruby-lsp.

`Support/lib/language_server.sh` has the functions the commands use.

# Tests

	ruby -Itest test/commands_test.rb

runs the commands with a fake `mate` and `$DIALOG` (on macOS, as they convert the server’s answers with `osascript`).

# License

If not otherwise specified (see below), files in this repository fall under the following license:

	Permission to copy, use, modify, sell and distribute this
	software is granted. This software is provided "as is" without
	express or implied warranty, and with no claim as to its
	suitability for any purpose.

An exception is made for files in readable text which contain their own license information, or files where an accompanying file exists (in the same directory) with a “-license” suffix added to the base-name name of the original file, and an extension of txt, html, or similar. For example “tidy” is accompanied by “tidy-license.txt”.
