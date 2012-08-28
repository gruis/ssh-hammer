require File.expand_path("../lib/ssh-hammer/version", __FILE__)
require "rubygems"
::Gem::Specification.new do |s|
  s.name                      = "ssh-hammer"
  s.version                   = SshHammer::VERSION
  s.platform                  = ::Gem::Platform::RUBY
  s.authors                   = ['Caleb Crane']
  s.email                     = ['ssh-hammer@simulacre.org']
  s.homepage                  = "http://github.com/simulacre/em-ssh"
  s.summary                   = 'Load test ssh servers'
  s.description               = ''
  s.required_rubygems_version = ">= 1.3.6"
  s.files                     = Dir["lib/**/*.rb", "bin/*", "*.md"]
  s.require_paths             = ['lib']
  s.executables               = Dir["bin/*"].map{|f| f.split("/")[-1] }
  s.license                   = 'MIT'

  # If you have C extensions, uncomment this line
  # s.extensions = "ext/extconf.rb"
  s.add_dependency "em-ssh", '0.4.2'
  s.add_dependency "net-ssh", '=2.1.4'
end
