# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'
require 'digest'
require 'fileutils'
require 'net/http'

# jq's test suite nests values 10,000 levels deep; the evaluator recurses on
# the Ruby stack, so run the tests with large thread stacks.
ENV['RUBY_THREAD_VM_STACK_SIZE'] ||= (256 * 1024 * 1024).to_s
ENV['RUBY_THREAD_MACHINE_STACK_SIZE'] ||= (256 * 1024 * 1024).to_s

# jq's own test suite (MIT license), downloaded into test/jq for
# test/upstream_test.rb. The files are pinned by tag and SHA-256.
JQ_TEST_TAG = 'jq-1.8.2'
JQ_TEST_DIR = File.join(__dir__, 'test', 'jq')
JQ_TEST_FILES = {
  'base64.test' => 'aec7a4812b4bdf937e77ba1261c5d51ece66308258d60ca2227b209a4398a64d',
  'jq.test' => '329689763b651096989bd8260b643731083fc5fd17f6bd7834d158713f738cbd',
  'man.test' => '3c25698e94d5199c75b784cc361cda9c6775389eb61f8f4fb05fde1a757ae3f9',
  'manonig.test' => '62738dd27ce0dbc4f21296e48270f20024274631cae4b9ffe85a0eecaa53af7f',
  'onig.test' => 'e82dab356709d4a5e4dfd8c71aced12ed1f42eb23208bac0eaf5e3f05bedef05',
  'optional.test' => '06d7249e3d9e09d572995e66276cd65f2da6f907a15e2f9cb012e672598ac5b9',
  'uri.test' => '530958297b8eac04093e742756ab0ecd57de4364a38ac69fa7fed693c381ec39'
}.freeze

def fetch(url, limit = 5)
  raise "too many redirects: #{url}" if limit.zero?

  res = Net::HTTP.get_response(URI(url))
  case res
  when Net::HTTPSuccess then res.body
  when Net::HTTPRedirection then fetch(res['location'], limit - 1)
  else raise "#{url}: #{res.code} #{res.message}"
  end
end

namespace :jq do
  desc "Download jq's test suite (#{JQ_TEST_TAG}) into test/jq"
  task :download do
    FileUtils.mkdir_p(JQ_TEST_DIR)
    JQ_TEST_FILES.each do |name, sha256|
      path = File.join(JQ_TEST_DIR, name)
      next if File.exist?(path) && Digest::SHA256.file(path).hexdigest == sha256

      body = fetch("https://raw.githubusercontent.com/jqlang/jq/#{JQ_TEST_TAG}/tests/#{name}")
      actual = Digest::SHA256.hexdigest(body)
      raise "#{name}: SHA-256 mismatch (#{actual})" unless actual == sha256

      File.binwrite(path, body)
      puts "downloaded #{name}"
    end
  end
end

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.test_files = FileList['test/**/*_test.rb']
end

desc 'Run tests (downloads jq
task default: :test
s test suite first)'
task test: 'jq:download'

task default: :test
