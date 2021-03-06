module GitStrategy
  # Uses alternate object stores to share object stores across worker nodes. This uses
  # git clone --shared for fast clones and checkouts. Repos are cloned
  # from a central location, which is typically an NFS mount on the workers.
  #
  # Scaling:
  # Unlike cloning over the git protocol, which is very cpu-intensive, this strategy
  # scales with available bandwidth on the server. Luckily, bandwidth use is mitigated somewhat
  # when using NFS thanks to client-side buffer cache. If you overwhelm the server,
  # get a bigger NIC or consider implementing improvement #1.
  #
  # When to use:
  # Use the shared strategy when you have enough workers to overwhelm your
  # normal git server and/or mirrors.
  #
  # Possible improvements:
  # 1. Add multiple shared roots and choose randomly between them. Poor man's client side load balancing.
  class SharedCache
    extend Benchmark

    class << self
      def clone_and_checkout(repo_url, commit)
        benchmark "SharedCache.clone_and_checkout(#{repo_url}, #{commit})" do
          repo_path = repo_url.match(/.+?([^\/]+\/[^\/]+\.git)\z/)[1]
          shared_repo_dir = File.join(Kochiku::Worker.settings.git_shared_root, repo_path)
          raise 'cannot find repo in shared repos' unless Dir.exists?(shared_repo_dir)

          # check that commit exists
          Dir.chdir(shared_repo_dir) do
            begin
              Cocaine::CommandLine.new('git', 'rev-list --quiet -n1 :commit').run(commit: commit)
            rescue Cocaine::ExitStatusError
              raise Kochiku::Worker::GitRepo::RefNotFoundError
            end
          end

          repo_namespace_and_name = repo_path.chomp('.git')
          repo_checkout_path = File.join(Kochiku::Worker::GitRepo::WORKING_DIR, repo_namespace_and_name)

          # No `git fetch` is needed if the clone already exists because the NFS
          # origin is continually up to date. However, a `git fetch` is needed if
          # you are going to be referencing a branch name and not a commit
          unless Dir.exist?(repo_checkout_path)
            Cocaine::CommandLine.new('git', 'clone --quiet --shared --no-checkout :repo :dir').run(repo: shared_repo_dir, dir: repo_checkout_path)
          end

          Dir.chdir(repo_checkout_path) do
            Cocaine::CommandLine.new('git', 'reset --hard').run
            Cocaine::CommandLine.new('git', 'clean -dfx -f').run
            Cocaine::CommandLine.new('git', 'checkout --quiet :commit').run(commit: commit)

            # init submodules
            Cocaine::CommandLine.new('git', 'submodule --quiet init').run

            # update submodules. attempt to use references. best-effort.
            submodules = Cocaine::CommandLine.new('git', 'config --get-regexp "^submodule\..*\.url$"', expected_outcodes: [0,1]).run
            submodules.each_line do |submodule|
              _, path, url = submodule.strip.match(/^submodule\.(.+?)\.url .+?([^\/]+\/[^\/\n]+)$/).to_a
              shared_repo_dir = File.join(Kochiku::Worker.settings.git_shared_root, url || 'does-not-exist')

              if Dir.exists?(shared_repo_dir)
                Cocaine::CommandLine.new('git', 'config --replace-all submodule.:path.url :shared').run(shared: shared_repo_dir, path: path)
              end
              Cocaine::CommandLine.new('git', 'submodule update -- :path').run(path: path)
            end
          end

          repo_checkout_path
        end
      end
    end
  end
end
