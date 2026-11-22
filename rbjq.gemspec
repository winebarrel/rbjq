# frozen_string_literal: true

require_relative 'lib/rbjq/version'

Gem::Specification.new do |spec|
  spec.name = 'rbjq'
  spec.version = Rbjq::VERSION
  spec.authors = ['winebarrel']
  spec.email = ['sugawara@winebarrel.jp']

  spec.summary = 'A pure Ruby implementation of jq'
  spec.description = 'rbjq is a jq-compatible JSON processor written in pure Ruby, ' \
                     'usable both as a library and as a command line tool.'
  spec.homepage = 'https://github.com/winebarrel/rbjq'
  spec.license = 'CC0-1.0'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb', 'exe/*', 'README.md', 'LICENSE', 'LICENSE-jq']
  spec.bindir = 'exe'
  spec.executables = ['rbjq']
  spec.require_paths = ['lib']
end
