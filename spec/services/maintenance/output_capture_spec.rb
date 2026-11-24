# frozen_string_literal: true

# rubocop:disable RSpec/Output, RSpec/ExpectOutput -- printing and swapping $stdout is what this spec checks
require 'rails_helper'
require 'rake'

RSpec.describe Maintenance::OutputCapture do
  let(:real_io) { StringIO.new }
  let(:proxy) { described_class::Proxy.new(real_io) }

  # Runs the block with +proxy+ installed as $stdout (the original one restored afterwards).
  def with_proxy
    original = $stdout
    $stdout = proxy
    yield
  ensure
    $stdout = original
  end

  it 'is installed at boot as $stdout, transparently wrapping the original stream' do
    expect(described_class.proxy?($stdout)).to be(true)
    expect($stdout.io).to respond_to(:write)
    expect(described_class).not_to be_active
  end

  it 'captures puts, print, putc, printf and $stdout.write inside the block' do
    result, console = with_proxy do
      described_class.capture do
        puts('one')
        print('two')
        putc('!')
        printf('%<n>03d', n: 7)
        $stdout.write('|written')
        $stdout << '|appended'
        :value
      end
    end
    expect(result).to eq(:value)
    expect(console).to eq("one\ntwo!007|written|appended")
    expect(real_io.string).to be_empty
  end

  it 'writes to the wrapped stream outside a capture' do
    with_proxy { puts('to the terminal') }
    expect(real_io.string).to eq("to the terminal\n")
  end

  it 'does not capture the output of another thread' do
    started = Queue.new
    release = Queue.new
    _result, console = with_proxy do
      described_class.capture do
        other = Thread.new do
          started << true
          release.pop
          puts('from the other thread')
        end
        started.pop
        puts('from the capturing thread')
        release << true
        other.join
      end
    end
    expect(console).to eq("from the capturing thread\n")
    expect(real_io.string).to eq("from the other thread\n")
  end

  it 'restores the previous state after an exception' do
    with_proxy do
      expect { described_class.capture { raise ArgumentError, 'boom' } }.to raise_error(ArgumentError, 'boom')
      expect(described_class).not_to be_active
      puts('after')
    end
    expect(real_io.string).to eq("after\n")
  end

  it 'supports nested captures, each with its own buffer' do
    outer = with_proxy do
      described_class.capture do
        puts('outer 1')
        _inner_result, inner = described_class.capture { puts('inner') }
        puts("outer 2 (inner: #{inner.strip})")
      end
    end
    expect(outer.last).to eq("outer 1\nouter 2 (inner: inner)\n")
  end

  it 'installs a temporary proxy when $stdout was replaced (e.g. by a spec matcher), then puts it back' do
    replaced = StringIO.new
    original = $stdout
    $stdout = replaced
    _result, console = described_class.capture { puts('captured anyway') }
    expect($stdout).to be(replaced)
    expect(console).to eq("captured anyway\n")
    expect(replaced.string).to be_empty
  ensure
    $stdout = original
  end

  it "never diverts RSpec's own output: the reporter stream is the original IO, even inside a capture" do
    stream = RSpec.configuration.output_stream
    expect(described_class.proxy?(stream)).to be(false) # (configured before the Rails boot installed the proxy)
    _result, console = described_class.capture do
      expect(described_class.proxy?(stream) ? stream.target : stream).to be(stream)
      stream.write('') # (a reporter write during a capture goes straight to the terminal)
      puts('only this is captured')
    end
    expect(console).to eq("only this is captured\n")
  end

  it 'lets a rake task run from a terminal print to the real stdout (no capture active)' do
    Rake::Task.define_task(:maintenance_output_capture_spec) { puts('rake says hello') } unless Rake::Task.task_defined?(:maintenance_output_capture_spec)
    task = Rake::Task[:maintenance_output_capture_spec]
    task.reenable
    expect { task.invoke }.to output("rake says hello\n").to_stdout_from_any_process
    # ...and the terminal is back afterwards (#clone returns a real copy of the wrapped IO, used to restore it):
    expect($stdout.clone).to be_a(IO) if described_class.proxy?($stdout)
  end

  it 'strips the ANSI escapes for display only' do
    expect(described_class.html("\e[1;32mOK\e[0m dots: \e[33m.\e[0m")).to eq('OK dots: .')
  end
end
# rubocop:enable RSpec/Output, RSpec/ExpectOutput
