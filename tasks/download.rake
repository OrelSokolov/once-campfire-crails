# frozen_string_literal: true

# ————— download: clones at pins —————

desc "Download competitor repositories at pinned revisions (download[c,go] — selectively)"
task :download, [:app] do |_t, args|
  FileUtils.mkdir_p(WORKSPACE)
  each_app(args[:app]).each do |app|
    dir = app_dir(app)
    if app == CRAILS_APP
      # Local repository: a symlink so the harness sees the source revision.
      FileUtils.ln_sf(REPO_ROOT, dir) unless File.symlink?(dir)
      step "crails: symlink #{dir} → #{REPO_ROOT}"
      next
    end
    cfg = APPS.fetch(app)
    if File.directory?(File.join(dir, ".git"))
      rev = capture!("git", "-C", dir, "rev-parse", "HEAD").strip
      if rev == cfg[:rev]
        step "#{app}: already at pin #{rev[0, 7]}"
      else
        step "#{app}: at #{rev[0, 7]}, checking out pin #{cfg[:rev][0, 7]}"
        sh?("git", "-C", dir, "checkout", "-q", "-d", cfg[:rev]) ||
          (sh!("git", "-C", dir, "fetch", "origin") && sh!("git", "-C", dir, "checkout", "-q", "-d", cfg[:rev]))
      end
    else
      step "#{app}: cloning #{cfg[:repo]} @ #{cfg[:rev][0, 7]}"
      sh!("git", "clone", cfg[:repo], dir)
      sh!("git", "-C", dir, "checkout", "-q", "-d", cfg[:rev])
    end
    # Submodules recursively (Go: reference → once-campfire-rust → once-campfire).
    sh!("git", "-C", dir, "submodule", "update", "--init", "--recursive")
  end
end
