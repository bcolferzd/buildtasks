require "buildtasks/exceptions"
require "buildtasks/mixins/tasks"
require "rake/tasklib"
require "forwardable"

module BuildTasks
  module GitBuildpackage
    class Tasks < ::Rake::TaskLib
      BUILD_CMD = 'debuild -i\.git -I.git -uc -us -b'

      include BuildTasks::Mixins::Tasks

      extend Forwardable
      def_delegators :@attributes, :name, :version, :source,
                     :patches, :changelog

      def initialize(attributes)
        @attributes = attributes
        validate_attributes
        define_tasks
      end

      private

      def abspath(path)
        File.join(Rake.original_dir, path)
      end

      def validate_attributes
        fail MissingAttributeError, "name"    unless name
        fail MissingAttributeError, "version" unless version
        fail MissingAttributeError, "source"  unless source

        patches.each { |p| fail Errno::ENOENT, p unless File.exist?(abspath(p)) }
      end

      def update_changelog # rubocop:disable MethodLength
        return unless changelog

        text = changelog[:text]
        args = if changelog[:version]
                 ["--newversion", changelog[:version], "--force-bad-version", text]
               elsif changelog[:suffix]
                 ["--local", changelog[:suffix], text]
               elsif changelog[:increment?] == true
                 ["--increment", text]
               else
                 [text]
               end
        sh "dch", "--no-auto-nmu", *args
      end

      def define_tasks # rubocop:disable MethodLength
        task :default => :build

        file git_dir do |t|
          sh "git", "clone", source, t.name
        end

        desc "Clone Git repository and checkout version"
        task :clone => git_dir do
          in_git_dir do
            sh "git", "checkout", "-qf", version.to_s
          end
        end

        desc "Apply any patches"
        task :patch => :clone do
          in_git_dir do
            patches.each { |p| sh "git", "apply", "-v", abspath(p) }
            update_changelog
            sh "git", "status", "-s"
          end
        end

        desc "Install build dependencies"
        task :deps => :patch do
          in_git_dir do
            control_file = "debian/control"
            fail Errno::ENOENT, control_file unless File.exist?(control_file)
            env = "DEBIAN_FRONTEND=noninteractive"
            sh sudo("#{env} mk-build-deps -i -r -t 'apt-get -y' #{control_file}")
          end
        end

        desc "Build packages"
        task :build => [:clone, :patch, :deps] do
          in_git_dir do
            sh "git-buildpackage", "--git-ignore-branch",
                                   "--git-ignore-new",
                                   "--git-builder=#{BUILD_CMD}"
          end
        end

        desc "Publish built packages"
        task :publish => :build do
          publish_dir = ENV["PUBLISH_DIR"]
          fail "PUBLISH_DIR variable not set in environment" unless publish_dir

          mkdir_p publish_dir
          cp Dir["*.deb"], publish_dir
        end

        require "rake/clean"
        CLEAN.include "git-*", "*.build", "*.changes", "*.orig.tar.gz"
        CLOBBER.include "*.deb"

        self
      end

      def git_dir
        "git-#{version.to_s.gsub("/", "-")}"
      end

      def in_git_dir
        cd(git_dir) { yield }
      end
    end
  end
end
