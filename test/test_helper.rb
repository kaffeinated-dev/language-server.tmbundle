# Runs the bundle’s commands as TextMate does (bash, with TextMate’s PATH and
# variables), with a fake mate that answers mate --lsp with the responses of
# the test, and a fake $DIALOG that answers prompts with @answer and menus
# with their first item. Both log their arguments.
#
# The commands convert responses with osascript, so they run on macOS only.

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

Encoding.default_external = Encoding::UTF_8

BUNDLE = File.expand_path('..', __dir__)

class CommandTest < Minitest::Test
  SAMPLE = <<~RUBY
    module Sample
      class Greeter
        def greet(name)
          "Hello, \#{name}!"
        end
      end
    end

    puts Sample::Greeter.new.greet("you")
  RUBY

  def setup
    @dir = File.realpath(Dir.mktmpdir)
    @project = File.join(@dir, 'project')
    FileUtils.mkdir_p(File.join(@project, 'lib'))
    File.write(File.join(@project, 'lib/sample.rb'), SAMPLE)
    @answer = 'hello'
    @responses = {}
    @status = 0
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # The response of mate --lsp METHOD, as JSON (a Hash is its result).
  def respond(method, response)
    @responses[method] = response.is_a?(String) ? response : JSON.generate(result: response)
  end

  def uri(file)
    "file://#{File.join(@project, file)}"
  end

  def location(file, line, character)
    { uri: uri(file), range: { start: { line: line, character: character }, end: { line: line, character: character + 5 } } }
  end

  # Runs the command named NAME (or the script of the bundle NAME, such as
  # Support/bin/format) in FILE, with the caret on LINE (from 1) at INDEX
  # (bytes from 0). Returns its status, output, and errors.
  def run_command(name, file: 'lib/sample.rb', line: 1, index: 0, word: nil, env: {})
    fakes = write_fakes
    path = File.join(@project, file)
    current_line = File.readlines(path)[line - 1].to_s.chomp
    program = name.start_with?('Support/') ? [File.join(BUNDLE, name)] : ['-c', plist(File.join(BUNDLE, 'Commands', "#{name}.tmCommand"))['command']]

    environment = {
      'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin',
      'HOME' => @dir,
      'LC_CTYPE' => 'en_US.UTF-8',
      'TM_BUNDLE_SUPPORT' => File.join(BUNDLE, 'Support'),
      'TM_SUPPORT_PATH' => '/support',
      'TM_MATE' => File.join(fakes, 'mate'),
      'DIALOG' => File.join(fakes, 'dialog'),
      'TM_FILEPATH' => path,
      'TM_DIRECTORY' => File.dirname(path),
      'TM_PROJECT_DIRECTORY' => @project,
      'TM_LINE_NUMBER' => line.to_s,
      'TM_LINE_INDEX' => index.to_s,
      'TM_CURRENT_LINE' => current_line,
      'TM_CURRENT_WORD' => word || current_word(current_line, index),
    }.merge(env)

    output, errors, status = Open3.capture3(environment, '/bin/bash', *program, unsetenv_others: true)
    { status: status.exitstatus, output: output, errors: errors }
  end

  # The arguments mate and $DIALOG were run with, one per line.
  def mate_log
    File.exist?(log('mate')) ? File.read(log('mate')) : ''
  end

  def dialog_log
    File.exist?(log('dialog')) ? File.read(log('dialog')) : ''
  end

  private

  def log(name)
    File.join(@dir, "#{name}.log")
  end

  def plist(path)
    JSON.parse(`/usr/bin/plutil -convert json -o - "#{path}"`)
  end

  def current_word(line, index)
    line.bytes[0...index].pack('C*').force_encoding('UTF-8')[/[[:alnum:]_?!]*\z/] + line.bytes[index..-1].to_a.pack('C*').force_encoding('UTF-8')[/\A[[:alnum:]_?!]*/]
  end

  def write_fakes
    fakes = File.join(@dir, 'fakes')
    responses = File.join(@dir, 'responses')
    FileUtils.mkdir_p([fakes, responses])
    @responses.each { |method, json| File.write(File.join(responses, method.tr('/', '_') + '.json'), json) }

    fake(fakes, 'mate', <<~BASH)
      printf '%s\\n' "$@" >> "#{log('mate')}"
      response="#{responses}/${2//\\//_}.json"
      [[ "$1" == --lsp && -f "$response" ]] && cat "$response"
      exit #{@status}
    BASH

    fake(fakes, 'dialog', <<~BASH)
      printf '%s\\n' "$@" >> "#{log('dialog')}"
      case "$1 $2" in
        "nib --load") echo 1 ;;
        "nib --modal") printf '<plist><dict><key>eventInfo</key><dict><key>returnArgument</key><string>%s</string></dict></dict></plist>' "#{@answer}" ;;
        menu*) printf '<plist><dict><key>value</key><string>%s</string></dict></plist>' "$(printf '%s' "$3" | /usr/bin/plutil -extract 0.value raw -o - -)" ;;
      esac
    BASH
    fakes
  end

  def fake(dir, name, script)
    path = File.join(dir, name)
    File.write(path, "#!/bin/bash\n" + script)
    File.chmod(0o755, path)
  end
end
