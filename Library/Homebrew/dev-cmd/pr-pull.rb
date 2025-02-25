# typed: true
# frozen_string_literal: true

require "cli/parser"
require "utils/github"
require "utils/github/artifacts"
require "tmpdir"
require "formula"

module Homebrew
  sig { returns(CLI::Parser) }
  def self.pr_pull_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        Download and publish bottles, and apply the bottle commit from a
        pull request with artifacts generated by GitHub Actions.
        Requires write access to the repository.
      EOS
      switch "--no-upload",
             description: "Download the bottles but don't upload them."
      switch "--no-commit",
             description: "Do not generate a new commit before uploading."
      switch "--no-cherry-pick",
             description: "Do not cherry-pick commits from the pull request branch."
      switch "-n", "--dry-run",
             description: "Print what would be done rather than doing it."
      switch "--clean",
             description: "Do not amend the commits from pull requests."
      switch "--keep-old",
             description: "If the formula specifies a rebuild version, " \
                          "attempt to preserve its value in the generated DSL."
      switch "--autosquash",
             description: "Automatically reformat and reword commits in the pull request to our " \
                          "preferred format."
      switch "--no-autosquash",
             description: "Skip automatically reformatting and rewording commits in the pull request to our " \
                          "preferred format.",
             disable:     true, # odisabled: remove this switch with 4.3.0
             hidden:      true
      switch "--branch-okay",
             description: "Do not warn if pulling to a branch besides the repository default (useful for testing)."
      switch "--resolve",
             description: "When a patch fails to apply, leave in progress and allow user to resolve, " \
                          "instead of aborting."
      switch "--warn-on-upload-failure",
             description: "Warn instead of raising an error if the bottle upload fails. " \
                          "Useful for repairing bottle uploads that previously failed."
      switch "--retain-bottle-dir",
             description: "Does not clean up the tmp directory for the bottle so it can be used later."
      flag   "--committer=",
             description: "Specify a committer name and email in `git`'s standard author format."
      flag   "--message=",
             depends_on:  "--autosquash",
             description: "Message to include when autosquashing revision bumps, deletions, and rebuilds."
      flag   "--artifact=",
             description: "Download artifacts with the specified name (default: `bottles`)."
      flag   "--tap=",
             description: "Target tap repository (default: `homebrew/core`)."
      flag   "--root-url=",
             description: "Use the specified <URL> as the root of the bottle's URL instead of Homebrew's default."
      flag   "--root-url-using=",
             description: "Use the specified download strategy class for downloading the bottle's URL instead of " \
                          "Homebrew's default."
      comma_array "--workflows",
                  description: "Retrieve artifacts from the specified workflow (default: `tests.yml`). " \
                               "Can be a comma-separated list to include multiple workflows."
      comma_array "--ignore-missing-artifacts",
                  description: "Comma-separated list of workflows which can be ignored if they have not been run."

      conflicts "--clean", "--autosquash"

      named_args :pull_request, min: 1
    end
  end

  # Separates a commit message into subject, body, and trailers.
  def self.separate_commit_message(message)
    subject = message.lines.first.strip

    # Skip the subject and separate lines that look like trailers (e.g. "Co-authored-by")
    # from lines that look like regular body text.
    trailers, body = message.lines.drop(1).partition { |s| s.match?(/^[a-z-]+-by:/i) }

    trailers = trailers.uniq.join.strip
    body = body.join.strip.gsub(/\n{3,}/, "\n\n")

    [subject, body, trailers]
  end

  def self.signoff!(git_repo, pull_request: nil, dry_run: false)
    subject, body, trailers = separate_commit_message(git_repo.commit_message)

    if pull_request
      # This is a tap pull request and approving reviewers should also sign-off.
      tap = Tap.from_path(git_repo.pathname)
      review_trailers = GitHub.approved_reviews(tap.user, tap.full_name.split("/").last, pull_request).map do |r|
        "Signed-off-by: #{r["name"]} <#{r["email"]}>"
      end
      trailers = trailers.lines.concat(review_trailers).map(&:strip).uniq.join("\n")

      # Append the close message as well, unless the commit body already includes it.
      close_message = "Closes ##{pull_request}."
      body += "\n\n#{close_message}" unless body.include? close_message
    end

    git_args = Utils::Git.git, "-C", git_repo.pathname, "commit", "--amend", "--signoff", "--allow-empty", "--quiet",
               "--message", subject, "--message", body, "--message", trailers

    if dry_run
      puts(*git_args)
    else
      safe_system(*git_args)
    end
  end

  def self.get_package(tap, subject_name, subject_path, content)
    if subject_path.to_s.start_with?("#{tap.cask_dir}/")
      cask = begin
        Cask::CaskLoader.load(content.dup)
      rescue Cask::CaskUnavailableError
        nil
      end
      return cask
    end

    begin
      Formulary.from_contents(subject_name, subject_path, content, :stable)
    rescue FormulaUnavailableError
      nil
    end
  end

  def self.determine_bump_subject(old_contents, new_contents, subject_path, reason: nil)
    subject_path = Pathname(subject_path)
    tap          = Tap.from_path(subject_path)
    subject_name = subject_path.basename.to_s.chomp(".rb")
    is_cask      = subject_path.to_s.start_with?("#{tap.cask_dir}/")
    name         = is_cask ? "cask" : "formula"

    new_package = get_package(tap, subject_name, subject_path, new_contents)

    return "#{subject_name}: delete #{reason}".strip if new_package.blank?

    old_package = get_package(tap, subject_name, subject_path, old_contents)

    if old_package.blank?
      "#{subject_name} #{new_package.version} (new #{name})"
    elsif old_package.version != new_package.version
      "#{subject_name} #{new_package.version}"
    elsif !is_cask && old_package.revision != new_package.revision
      "#{subject_name}: revision #{reason}".strip
    elsif is_cask && old_package.sha256 != new_package.sha256
      "#{subject_name}: checksum update #{reason}".strip
    else
      "#{subject_name}: #{reason || "rebuild"}".strip
    end
  end

  # Cherry picks a single commit that modifies a single file.
  # Potentially rewords this commit using {determine_bump_subject}.
  def self.reword_package_commit(commit, file, git_repo:, reason: "", verbose: false, resolve: false)
    package_file = git_repo.pathname / file
    package_name = package_file.basename.to_s.chomp(".rb")

    odebug "Cherry-picking #{package_file}: #{commit}"
    Utils::Git.cherry_pick!(git_repo.to_s, commit, verbose: verbose, resolve: resolve)

    old_package = Utils::Git.file_at_commit(git_repo.to_s, file, "HEAD^")
    new_package = Utils::Git.file_at_commit(git_repo.to_s, file, "HEAD")

    bump_subject = determine_bump_subject(old_package, new_package, package_file, reason: reason).strip
    subject, body, trailers = separate_commit_message(git_repo.commit_message)

    if subject != bump_subject && !subject.start_with?("#{package_name}:")
      safe_system("git", "-C", git_repo.pathname, "commit", "--amend", "-q",
                  "-m", bump_subject, "-m", subject, "-m", body, "-m", trailers)
      ohai bump_subject
    else
      ohai subject
    end
  end

  # Cherry picks multiple commits that each modify a single file.
  # Words the commit according to {determine_bump_subject} with the body
  # corresponding to all the original commit messages combined.
  def self.squash_package_commits(commits, file, git_repo:, reason: "", verbose: false, resolve: false)
    odebug "Squashing #{file}: #{commits.join " "}"

    # Format commit messages into something similar to `git fmt-merge-message`.
    # * subject 1
    # * subject 2
    #   optional body
    # * subject 3
    messages = []
    trailers = []
    commits.each do |commit|
      subject, body, trailer = separate_commit_message(git_repo.commit_message(commit))
      body = body.lines.map { |line| "  #{line.strip}" }.join("\n")
      messages << "* #{subject}\n#{body}".strip
      trailers << trailer
    end

    # Get the set of authors in this series.
    authors = Utils.safe_popen_read("git", "-C", git_repo.pathname, "show",
                                    "--no-patch", "--pretty=%an <%ae>", *commits).lines.map(&:strip).uniq.compact

    # Get the author and date of the first commit of this series, which we use for the squashed commit.
    original_author = authors.shift
    original_date = Utils.safe_popen_read "git", "-C", git_repo.pathname, "show", "--no-patch", "--pretty=%ad",
                                          commits.first

    # Generate trailers for coauthors and combine them with the existing trailers.
    co_author_trailers = authors.map { |au| "Co-authored-by: #{au}" }
    trailers = [trailers + co_author_trailers].flatten.uniq.compact

    # Apply the patch series but don't commit anything yet.
    Utils::Git.cherry_pick!(git_repo.pathname, "--no-commit", *commits, verbose: verbose, resolve: resolve)

    # Determine the bump subject by comparing the original state of the tree to its current state.
    package_file = git_repo.pathname / file
    old_package = Utils::Git.file_at_commit(git_repo.pathname, file, "#{commits.first}^")
    new_package = package_file.read
    bump_subject = determine_bump_subject(old_package, new_package, package_file, reason: reason)

    # Commit with the new subject, body, and trailers.
    safe_system("git", "-C", git_repo.pathname, "commit", "--quiet",
                "-m", bump_subject, "-m", messages.join("\n"), "-m", trailers.join("\n"),
                "--author", original_author, "--date", original_date, "--", file)
    ohai bump_subject
  end

  # TODO: fix test in `test/dev-cmd/pr-pull_spec.rb` and assume `cherry_picked: false`.
  def self.autosquash!(original_commit, tap:, reason: "", verbose: false, resolve: false, cherry_picked: true)
    git_repo = tap.git_repo
    original_head = git_repo.head_ref

    commits = Utils.safe_popen_read("git", "-C", tap.path, "rev-list",
                                    "--reverse", "#{original_commit}..HEAD").lines.map(&:strip)

    # Generate a bidirectional mapping of commits <=> formula/cask files.
    files_to_commits = {}
    commits_to_files = commits.to_h do |commit|
      files = Utils.safe_popen_read("git", "-C", tap.path, "diff-tree", "--diff-filter=AMD",
                                    "-r", "--name-only", "#{commit}^", commit).lines.map(&:strip)
      files.each do |file|
        files_to_commits[file] ||= []
        files_to_commits[file] << commit
        tap_file = (tap.path/file).to_s
        if (tap_file.start_with?("#{tap.formula_dir}/") || tap_file.start_with?("#{tap.cask_dir}/")) &&
           File.extname(file) == ".rb"
          next
        end

        odie <<~EOS
          Autosquash can only squash commits that modify formula or cask files.
            File:   #{file}
            Commit: #{commit}
        EOS
      end
      [commit, files]
    end

    # Reset to state before cherry-picking.
    safe_system "git", "-C", tap.path, "reset", "--hard", original_commit

    # Iterate over every commit in the pull request series, but if we have to squash
    # multiple commits into one, ensure that we skip over commits we've already squashed.
    processed_commits = T.let([], T::Array[String])
    commits.each do |commit|
      next if processed_commits.include? commit

      files = commits_to_files[commit]
      if files.length == 1 && files_to_commits[files.first].length == 1
        # If there's a 1:1 mapping of commits to files, just cherry pick and (maybe) reword.
        reword_package_commit(
          commit, files.first, git_repo: git_repo, reason: reason, verbose: verbose, resolve: resolve
        )
        processed_commits << commit
      elsif files.length == 1 && files_to_commits[files.first].length > 1
        # If multiple commits modify a single file, squash them down into a single commit.
        file = files.first
        commits = files_to_commits[file]
        squash_package_commits(commits, file, git_repo: git_repo, reason: reason, verbose: verbose, resolve: resolve)
        processed_commits += commits
      else
        # We can't split commits (yet) so just raise an error.
        odie <<~EOS
          Autosquash can't split commits that modify multiple files.
            Commit: #{commit}
            Files:  #{files.join " "}
        EOS
      end
    end
  rescue
    opoo "Autosquash encountered an error; resetting to original state at #{original_head}"
    system "git", "-C", tap.path, "reset", "--hard", original_head
    system "git", "-C", tap.path, "cherry-pick", "--abort" if cherry_picked
    raise
  end

  def self.cherry_pick_pr!(user, repo, pull_request, args:, path: ".")
    if args.dry_run?
      puts <<~EOS
        git fetch --force origin +refs/pull/#{pull_request}/head
        git merge-base HEAD FETCH_HEAD
        git cherry-pick --ff --allow-empty $merge_base..FETCH_HEAD
      EOS
      return
    end

    commits = GitHub.pull_request_commits(user, repo, pull_request)
    safe_system "git", "-C", path, "fetch", "--quiet", "--force", "origin", commits.last
    ohai "Using #{commits.count} commit#{"s" if commits.count != 1} from ##{pull_request}"
    Utils::Git.cherry_pick!(path, "--ff", "--allow-empty", *commits, verbose: args.verbose?, resolve: args.resolve?)
  end

  def self.formulae_need_bottles?(tap, original_commit, labels, args:)
    return false if args.dry_run?

    return false if labels.include?("CI-syntax-only") || labels.include?("CI-no-bottles")

    changed_packages(tap, original_commit).any? do |f|
      !f.instance_of?(Cask::Cask)
    end
  end

  def self.changed_packages(tap, original_commit)
    formulae = Utils.popen_read("git", "-C", tap.path, "diff-tree",
                                "-r", "--name-only", "--diff-filter=AM",
                                original_commit, "HEAD", "--", tap.formula_dir)
                    .lines
                    .filter_map do |line|
      next unless line.end_with? ".rb\n"

      name = "#{tap.name}/#{File.basename(line.chomp, ".rb")}"
      if Homebrew::EnvConfig.disable_load_formula?
        opoo "Can't check if updated bottles are necessary as HOMEBREW_DISABLE_LOAD_FORMULA is set!"
        break
      end
      begin
        Formulary.resolve(name)
      rescue FormulaUnavailableError
        nil
      end
    end
    casks = Utils.popen_read("git", "-C", tap.path, "diff-tree",
                             "-r", "--name-only", "--diff-filter=AM",
                             original_commit, "HEAD", "--", tap.cask_dir)
                 .lines
                 .filter_map do |line|
      next unless line.end_with? ".rb\n"

      name = "#{tap.name}/#{File.basename(line.chomp, ".rb")}"
      begin
        Cask::CaskLoader.load(name)
      rescue Cask::CaskUnavailableError
        nil
      end
    end
    formulae + casks
  end

  def self.pr_check_conflicts(repo, pull_request)
    long_build_pr_files = GitHub.issues(
      repo: repo, state: "open", labels: "no long build conflict",
    ).each_with_object({}) do |long_build_pr, hash|
      next unless long_build_pr.key?("pull_request")

      number = long_build_pr["number"]
      next if number == pull_request.to_i

      GitHub.get_pull_request_changed_files(repo, number).each do |file|
        key = file["filename"]
        hash[key] ||= []
        hash[key] << number
      end
    end

    return if long_build_pr_files.blank?

    this_pr_files = GitHub.get_pull_request_changed_files(repo, pull_request)

    conflicts = this_pr_files.each_with_object({}) do |file, hash|
      filename = file["filename"]
      next unless long_build_pr_files.key?(filename)

      long_build_pr_files[filename].each do |pr_number|
        key = "#{repo}/pull/#{pr_number}"
        hash[key] ||= []
        hash[key] << filename
      end
    end

    return if conflicts.blank?

    # Raise an error, display the conflicting PR. For example:
    # Error: You are trying to merge a pull request that conflicts with a long running build in:
    # {
    #   "homebrew-core/pull/98809": [
    #    "Formula/icu4c.rb",
    #    "Formula/node@10.rb"
    #   ]
    # }
    odie <<~EOS
      You are trying to merge a pull request that conflicts with a long running build in:
      #{JSON.pretty_generate(conflicts)}
    EOS
  end

  def self.pr_pull
    args = pr_pull_args.parse

    # Needed when extracting the CI artifact.
    ensure_executable!("unzip", reason: "extracting CI artifacts")

    workflows = args.workflows.presence || ["tests.yml"]
    artifact = args.artifact || "bottles"
    tap = Tap.fetch(args.tap || CoreTap.instance.name)
    raise TapUnavailableError, tap.name unless tap.installed?

    Utils::Git.set_name_email!(committer: args.committer.blank?)
    Utils::Git.setup_gpg!

    if (committer = args.committer)
      committer = Utils.parse_author!(committer)
      ENV["GIT_COMMITTER_NAME"] = committer[:name]
      ENV["GIT_COMMITTER_EMAIL"] = committer[:email]
    end

    args.named.uniq.each do |arg|
      arg = "#{tap.default_remote}/pull/#{arg}" if arg.to_i.positive?
      url_match = arg.match HOMEBREW_PULL_OR_COMMIT_URL_REGEX
      _, user, repo, pr = *url_match
      odie "Not a GitHub pull request: #{arg}" unless pr

      git_repo = tap.git_repo
      if !git_repo.default_origin_branch? && !args.branch_okay? && !args.no_commit? && !args.no_cherry_pick?
        opoo "Current branch is #{git_repo.branch_name}: do you need to pull inside #{git_repo.origin_branch_name}?"
      end

      pr_labels = GitHub.pull_request_labels(user, repo, pr)
      if pr_labels.include?("autosquash") && !args.autosquash?
        opoo "Pull request is labelled `autosquash`: do you need to pass `--autosquash`?"
      end

      pr_check_conflicts("#{user}/#{repo}", pr)

      ohai "Fetching #{tap} pull request ##{pr}"
      dir = Dir.mktmpdir pr
      begin
        cd dir do
          current_branch_head = ENV["GITHUB_SHA"] || tap.git_head
          original_commit = if args.no_cherry_pick?
            # TODO: Handle the case where `merge-base` returns multiple commits.
            Utils.safe_popen_read("git", "-C", tap.path, "merge-base", "origin/HEAD", current_branch_head).strip
          else
            current_branch_head
          end
          odebug "Pull request merge-base: #{original_commit}"

          unless args.no_commit?
            cherry_pick_pr!(user, repo, pr, path: tap.path, args: args) unless args.no_cherry_pick?
            if args.autosquash? && !args.dry_run?
              autosquash!(original_commit, tap: tap, cherry_picked: !args.no_cherry_pick?,
                          verbose: args.verbose?, resolve: args.resolve?, reason: args.message)
            end
            signoff!(git_repo, pull_request: pr, dry_run: args.dry_run?) unless args.clean?
          end

          unless formulae_need_bottles?(tap, original_commit, pr_labels, args: args)
            ohai "Skipping artifacts for ##{pr} as the formulae don't need bottles"
            next
          end

          workflows.each do |workflow|
            workflow_run = GitHub.get_workflow_run(
              user, repo, pr, workflow_id: workflow, artifact_name: artifact
            )
            if args.ignore_missing_artifacts.present? &&
               args.ignore_missing_artifacts.include?(workflow) &&
               workflow_run.first.blank?
              # Ignore that workflow as it was not executed and we specified
              # that we could skip it.
              ohai "Ignoring workflow #{workflow} as requested by `--ignore-missing-artifacts`"
              next
            end

            ohai "Downloading bottles for workflow: #{workflow}"
            url = GitHub.get_artifact_url(workflow_run)
            GitHub.download_artifact(url, pr)
          end

          next if args.no_upload?

          upload_args = ["pr-upload"]
          upload_args << "--debug" if args.debug?
          upload_args << "--verbose" if args.verbose?
          upload_args << "--no-commit" if args.no_commit?
          upload_args << "--dry-run" if args.dry_run?
          upload_args << "--keep-old" if args.keep_old?
          upload_args << "--warn-on-upload-failure" if args.warn_on_upload_failure?
          upload_args << "--committer=#{args.committer}" if args.committer
          upload_args << "--root-url=#{args.root_url}" if args.root_url
          upload_args << "--root-url-using=#{args.root_url_using}" if args.root_url_using
          safe_system HOMEBREW_BREW_FILE, *upload_args
        end
      ensure
        if args.retain_bottle_dir? && ENV["GITHUB_ACTIONS"]
          ohai "Bottle files retained at:", dir
          File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |f|
            f.puts "bottle_path=#{dir}"
          end
        else
          FileUtils.remove_entry dir
        end
      end
    end
  end
end
