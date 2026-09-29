require_relative 'test_helper'

class CompleteTest < CommandTest
  # “Greeter” in the last line of the sample, typed as “Sample::Gre”.
  def completions
    {
      items: [
        { label: 'map_every(enumerable, nth, fun)', filterText: 'map_every', sortText: '2', insertTextFormat: 2, textEdit: { newText: 'map_every(${1:enumerable}, ${2:nth}, ${3:fun})' } },
        { label: 'map(enumerable, fun)', filterText: 'map', sortText: '1', insertTextFormat: 2, textEdit: { newText: 'map(${1:enumerable}, ${2:fun})' } },
        { label: 'Sample::Greeter', sortText: '0', textEdit: { newText: 'Sample::Greeter', range: { start: { line: 8, character: 5 }, end: { line: 8, character: 16 } } } },
        { label: 'Other::Gre', sortText: '3', textEdit: { newText: 'Other::Greeting', range: { start: { line: 8, character: 5 }, end: { line: 8, character: 16 } } } },
        { label: '$money', sortText: '4', insertText: '$money$' },
      ],
    }
  end

  def test_completions_are_shown_in_a_popup
    File.write(File.join(@project, 'lib/sample.rb'), SAMPLE.sub('Sample::Greeter.new', 'Sample::Gre'))
    respond('textDocument/completion', completions)

    result = run_command('Complete', line: 9, index: 16)
    assert_equal 200, result[:status], result[:errors]
    assert_equal "--lsp\ntextDocument/completion\n--line\n9:17\n", mate_log

    dialog = dialog_log
    assert_match(/\Apopup\n--suggestions\n<\?xml/, dialog)
    assert_includes dialog, "\n--alreadyTyped\nGre\n--additionalWordCharacters\n?!\n"
    assert_includes dialog, '<string>map(enumerable, fun)</string>'
    assert_includes dialog, '<string>(${1:enumerable}, ${2:fun})</string>'
    assert_operator dialog.index('map(enumerable'), :<, dialog.index('map_every(enumerable')

    # The word the edit makes from “Gre”, and none for an edit of the text before it.
    assert_includes dialog, "<key>display</key>\n\t\t<string>Sample::Greeter</string>\n\t\t<key>match</key>\n\t\t<string>Greeter</string>"
    refute_includes dialog, 'Other::Gre'

    # Plain text is inserted as a snippet, escaped.
    assert_includes dialog, '<string>\\$</string>'
  end

  def test_errors_are_shown_in_a_tool_tip
    respond('textDocument/completion', '{"error":{"code":-32601,"message":"There is no language server for this document."}}')
    assert_equal({ status: 206, output: '', errors: 'There is no language server for this document.' }, run_command('Complete'))

    @status = 64
    result = run_command('Complete')
    assert_equal 206, result[:status]
    assert_match(/\AThis needs TextMate 2.0.23\+kaffeinated.6/, result[:errors])

    @status = 0
    respond('textDocument/completion', [])
    assert_equal 'No completions.', run_command('Complete')[:errors]
  end

  def test_completions_for_other_bundles
    respond('textDocument/completion', completions)
    script = File.join(BUNDLE, 'Support/bin/completions')
    run_command('Complete', line: 9, index: 16) # For the fakes

    output, status = Open3.capture2e({ 'TM_BUNDLE_SUPPORT' => '/elsewhere', 'TM_MATE' => File.join(@dir, 'fakes/mate'), 'TM_LINE_NUMBER' => '9', 'TM_LINE_INDEX' => '16', 'TM_CURRENT_LINE' => 'puts Sample::Gre' }, '/bin/bash', script)
    assert status.success?, output
    assert_match(/\A<\?xml.*<string>Greeter<\/string>/m, output)
  end
end

class DocumentationTest < CommandTest
  def test_hover_information_is_shown_in_a_tool_tip
    respond('textDocument/hover', contents: { kind: 'markdown', value: "```ruby\nSample::Greeter\n```\n\n**Definitions**: [sample.rb](file:///p/lib/sample.rb#L2)\n\nGreets `people`." })

    # The caret right after “Greeter”: the request is for its last character.
    result = run_command('Documentation Tooltip', line: 9, index: 20)
    assert_equal 200, result[:status], result[:errors]
    assert_includes mate_log, "--line\n9:20\n"
    assert_match(/\Atooltip\n--html\n<style>/, dialog_log)
    assert_includes dialog_log, '<pre>Sample::Greeter</pre><p><b>Definitions</b>: sample.rb</p><p>Greets <code>people</code>.</p>'

    respond('textDocument/hover', nil)
    assert_equal 'No information about this.', run_command('Documentation Tooltip', line: 9, index: 18)[:errors]
    assert_includes mate_log, "--line\n9:19\n" # Inside the word, as it is
  end
end

class DefinitionTest < CommandTest
  def test_the_only_definition_is_opened
    respond('textDocument/definition', [{ targetUri: uri('lib/sample.rb'), targetRange: location('lib/sample.rb', 1, 2)[:range], targetSelectionRange: location('lib/sample.rb', 1, 8)[:range] }])

    result = run_command('Go to Definition', line: 9, index: 15)
    assert_equal 200, result[:status], result[:errors]
    assert_includes mate_log, "--lsp\ntextDocument/definition\n--line\n9:16\n"
    assert_includes mate_log, "-l\n2:9\n#{File.join(@project, 'lib/sample.rb')}\n"
    assert_equal '', dialog_log
  end

  def test_one_of_several_definitions_is_chosen
    File.write(File.join(@project, 'lib/other.rb'), "module Sample\n  class Greeter; end\nend\n")
    respond('textDocument/definition', [location('lib/sample.rb', 1, 8), location('lib/other.rb', 1, 8), location('lib/sample.rb', 1, 8)])

    assert_equal 200, run_command('Go to Definition', line: 9, index: 15)[:status]
    menu = dialog_log
    assert_includes menu, '<string>lib/sample.rb:2 — class Greeter</string>'
    assert_includes menu, '<string>lib/other.rb:2 — class Greeter; end</string>'
    assert_equal 2, menu.scan('<key>title</key>').size # Once each
    assert_includes mate_log, "-l\n2:9\n#{File.join(@project, 'lib/sample.rb')}\n"

    respond('textDocument/definition', [])
    assert_equal({ status: 206, output: '', errors: 'No definition found.' }, run_command('Go to Definition'))
  end
end

class ReferencesTest < CommandTest
  def test_references_are_listed_by_file
    File.write(File.join(@project, 'lib/other.rb'), "Sample::Greeter.new\n")
    respond('textDocument/references', [location('lib/sample.rb', 1, 8), location('lib/other.rb', 0, 8), location('lib/sample.rb', 1, 8)])

    result = run_command('Find References', line: 2, index: 10, word: 'Greeter')
    assert_equal 0, result[:status], result[:errors]
    html = result[:output]
    assert_includes html, '<title>References to Greeter</title>'
    assert_includes html, '2 references in 2 files'
    assert_includes html, '<h2>lib/sample.rb</h2>'
    assert_match(%r{sample.rb&amp;line=2&amp;column=9"><span class="line">2</span> <code>class Greeter</code>}, html)
    assert_includes mate_log, "--lsp-params\n{\"context\":{\"includeDeclaration\":true}}\n"

    respond('textDocument/references', [])
    assert_match(/\ANo references found./, run_command('Find References')[:errors])
  end
end

class QuickFixTest < CommandTest
  def edit
    { changes: { uri('lib/sample.rb') => [{ newText: '_name', range: { start: { line: 2, character: 14 }, end: { line: 2, character: 18 } } }] } }
  end

  def test_a_quick_fix_is_chosen_and_applied
    respond('textDocument/codeAction', [{ kind: 'quickfix', title: 'Prefix with _', edit: edit }])
    respond('workspace/applyEdit', applied: true)

    assert_equal 200, run_command('Quick Fix', line: 3)[:status]
    assert_includes dialog_log, '<string>Prefix with _</string>'
    assert_includes mate_log, "--lsp\nworkspace/applyEdit\n--line\n3:1\n--lsp-params\n#{JSON.generate(label: 'Prefix with _', edit: edit)}\n"

    respond('workspace/applyEdit', applied: false, failureReason: 'sample.rb changed on disk.')
    assert_equal({ status: 206, output: '', errors: 'sample.rb changed on disk.' }, run_command('Quick Fix', line: 3))

    respond('textDocument/codeAction', [])
    assert_equal 'No quick fixes for this line.', run_command('Quick Fix')[:errors]
  end

  def test_a_command_is_run_by_the_server
    respond('textDocument/codeAction', [{ title: 'Toggle block style', command: 'rubyLsp.toggleBlock', arguments: [1] }])
    respond('workspace/executeCommand', nil)

    assert_equal 200, run_command('Quick Fix')[:status]
    assert_includes mate_log, "workspace/executeCommand\n--line\n1:1\n--lsp-params\n{\"command\":\"rubyLsp.toggleBlock\",\"arguments\":[1]}\n"
  end

  def test_an_action_is_resolved_for_its_edit
    action = { title: 'Refactor: Extract Variable', kind: 'refactor.extract', data: { range: { start: { line: 8, character: 5 }, end: { line: 8, character: 24 } } } }
    respond('textDocument/codeAction', [action])
    respond('codeAction/resolve', action.merge(edit: edit))
    respond('workspace/applyEdit', applied: true)

    assert_equal 200, run_command('Quick Fix', line: 9)[:status]
    assert_includes mate_log, "--lsp\ncodeAction/resolve\n--line\n9:1\n--lsp-params\n#{JSON.generate(action)}\n"
    assert_includes mate_log, "--lsp-params\n#{JSON.generate(label: 'Refactor: Extract Variable', edit: edit)}\n"
  end

  def test_actions_are_for_the_selection
    respond('textDocument/codeAction', [])

    # “Sample::Greeter.new” selected, on the caret’s line (after “é”, two bytes).
    File.write(File.join(@project, 'lib/sample.rb'), SAMPLE.sub('puts ', 'é = '))
    result = run_command('Quick Fix', line: 9, index: 24, env: { 'TM_SELECTION' => '9:25-9:6' })
    assert_equal 'No quick fixes for this selection.', result[:errors]
    assert_includes mate_log, "--lsp-params\n{\"range\":{\"start\":{\"line\":8,\"character\":4},\"end\":{\"line\":8,\"character\":23}}}\n"

    # Lines 3 to 5, and the lines of a selection from the middle of one.
    run_command('Quick Fix', line: 6, env: { 'TM_SELECTION' => '3:1-6:1' })
    assert_includes mate_log, "{\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":5,\"character\":0}}}\n"
    run_command('Quick Fix', line: 5, index: 3, env: { 'TM_SELECTION' => '3:5-5:4' })
    assert_includes mate_log, "{\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":5,\"character\":0}}}\n"

    # Without a selection, the line.
    assert_equal 'No quick fixes for this line.', run_command('Quick Fix', line: 9, env: { 'TM_SELECTION' => '9:1' })[:errors]
  end
end

class RenameTest < CommandTest
  def edit
    { changes: { uri('lib/sample.rb') => [{ newText: 'Welcomer', range: location('lib/sample.rb', 1, 8)[:range] }] } }
  end

  def test_a_symbol_is_renamed
    @answer = 'Welcomer'
    respond('textDocument/prepareRename', location('lib/sample.rb', 1, 8)[:range].merge(end: { line: 1, character: 15 }))
    respond('textDocument/rename', edit)
    respond('workspace/applyEdit', applied: true)

    assert_equal 200, run_command('Rename Symbol', line: 2, index: 15, word: 'Greeter')[:status]
    assert_includes dialog_log, 'string = "Greeter";'
    assert_includes mate_log, "--lsp\ntextDocument/prepareRename\n--line\n2:15\n"
    assert_includes mate_log, "--lsp\ntextDocument/rename\n--line\n2:15\n--lsp-params\n{\"newName\":\"Welcomer\"}\n"
    assert_includes mate_log, "--lsp-params\n#{JSON.generate(label: 'Rename to Welcomer', edit: edit)}\n"

    respond('textDocument/rename', nil)
    assert_equal 'This can’t be renamed.', run_command('Rename Symbol', line: 2, index: 15, word: 'Greeter')[:errors]
  end

  def test_the_name_replaced_is_asked_for
    @answer = 'Sample::Welcomer'
    respond('textDocument/rename', edit)
    respond('workspace/applyEdit', applied: true)

    # The range of a constant path, a placeholder, and a server without prepareRename.
    respond('textDocument/prepareRename', { start: { line: 8, character: 5 }, end: { line: 8, character: 20 } })
    assert_equal 200, run_command('Rename Symbol', line: 9, index: 18, word: 'Greeter')[:status]
    assert_includes dialog_log, 'string = "Sample::Greeter";'

    respond('textDocument/prepareRename', range: location('lib/sample.rb', 8, 5)[:range], placeholder: 'Greeter')
    run_command('Rename Symbol', line: 9, index: 18, word: 'Greeter')
    assert_includes dialog_log, 'string = "Greeter";'

    respond('textDocument/prepareRename', '{"error":{"code":-32601,"message":"Method not found"}}')
    run_command('Rename Symbol', line: 9, index: 18, word: 'Gree')
    assert_includes dialog_log, 'string = "Gree";'

    respond('textDocument/prepareRename', nil)
    assert_equal 'This can’t be renamed.', run_command('Rename Symbol', line: 9, index: 18)[:errors]

    respond('textDocument/prepareRename', '{"error":{"code":-32601,"message":"Method not found"}}')
    respond('textDocument/rename', '{"error":{"code":-32601,"message":"Method not found"}}')
    assert_equal 'The language server of this document can’t do this.', run_command('Rename Symbol', line: 9, index: 18)[:errors]
  end

  def test_nothing_happens_for_the_same_name
    @answer = 'Greeter'
    respond('textDocument/prepareRename', { defaultBehavior: true })
    assert_equal 200, run_command('Rename Symbol', line: 2, index: 10, word: 'Greeter')[:status]
    refute_includes mate_log, 'textDocument/rename'
  end
end

class SymbolTest < CommandTest
  def test_a_symbol_is_found_by_name_and_opened
    symbol = { name: 'Sample::Greeter', kind: 5, location: location('lib/sample.rb', 1, 2) }
    respond('workspace/symbol', [symbol, symbol])

    assert_equal 200, run_command('Go to Symbol in Project', word: 'Greeter')[:status]
    assert_includes dialog_log, 'string = "Greeter";'
    assert_includes mate_log, "--lsp-params\n{\"query\":\"hello\"}\n"
    assert_includes mate_log, "-l\n2:3\n#{File.join(@project, 'lib/sample.rb')}\n" # Once, so opened without a menu

    respond('workspace/symbol', [])
    assert_match(/\ANo symbols named “hello”/, run_command('Go to Symbol in Project')[:errors])
  end
end
