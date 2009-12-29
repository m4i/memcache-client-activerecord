require 'rubygems'
require 'rake'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gem|
    gem.name = "memcache-client-activerecord"
    gem.summary = %Q{memcache-client with ActiveRecord backend}
    gem.description = %Q{memcache-client-activerecord has the same interface as memcache-client, and provides the functionality of saving to ActiveRecord instead of Memcached.}
    gem.email = "m.ishihara@gmail.com"
    gem.homepage = "http://github.com/m4i/memcache-client-activerecord"
    gem.authors = ["ISHIHARA Masaki"]
    gem.rubyforge_project = "mc-activerecord"
    gem.add_runtime_dependency "activerecord", ">= 2.1"
    gem.add_development_dependency "rspec", ">= 1.2.9"
    gem.add_development_dependency "memcache-client", ">= 1.7.7"
    # gem is a Gem::Specification... see http://www.rubygems.org/read/chapter/20 for additional settings
  end
  Jeweler::GemcutterTasks.new
  Jeweler::RubyforgeTasks.new do |rubyforge|
    rubyforge.doc_task = "rdoc"
  end
rescue LoadError
  puts "Jeweler (or a dependency) not available. Install it with: gem install jeweler"
end

require 'spec/rake/spectask'
Spec::Rake::SpecTask.new(:spec) do |spec|
  spec.libs << 'lib' << 'spec'
  spec.spec_files = FileList['spec/**/*_spec.rb']
end

Spec::Rake::SpecTask.new(:rcov) do |spec|
  spec.libs << 'lib' << 'spec'
  spec.pattern = 'spec/**/*_spec.rb'
  spec.rcov = true
end

task :spec => :check_dependencies

task :default => :spec

require 'rake/rdoctask'
Rake::RDocTask.new do |rdoc|
  version = File.exist?('VERSION') ? File.read('VERSION') : ""

  rdoc.rdoc_dir = 'rdoc'
  rdoc.title = "memcache-client-activerecord #{version}"
  rdoc.rdoc_files.include('README*')
  rdoc.rdoc_files.include('lib/**/*.rb')
end
