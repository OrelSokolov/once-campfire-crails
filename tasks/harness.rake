# frozen_string_literal: true

# ————— harness: verifier + seed —————

desc "Clone the harness, apply the crails patch, bin/check, build loadgen, build the seed database"
task :harness do
  unless File.directory?(File.join(HARNESS, ".git"))
    step "Cloning harness #{HARNESS_REPO} @ #{HARNESS_REV[0, 7]}"
    sh!("git", "clone", HARNESS_REPO, HARNESS)
    sh!("git", "-C", HARNESS, "checkout", "-q", "-d", HARNESS_REV)
  end
  dirty = !capture!("git", "-C", HARNESS, "status", "--porcelain", "--untracked-files=no").strip.empty?
  unless dirty
    abort "Patch not found: #{HARNESS_PATCH}" unless File.readable?(HARNESS_PATCH)
    sh!("git", "-C", HARNESS, "apply", HARNESS_PATCH)
    step "harness: crails patch applied"
  end
  # CRails into the workspace (the harness looks for siblings).
  FileUtils.ln_sf(REPO_ROOT, app_dir(CRAILS_APP)) unless File.symlink?(app_dir(CRAILS_APP))

  env = harness_env
  sh!("cargo", "build", "--release", "--locked", "--manifest-path", File.join(HARNESS, "loadgen", "Cargo.toml"), env: env)
  sh!(File.join(HARNESS, "bin", "check"), env: env)

  fixtures = File.join(HARNESS, "fixtures", "default")
  if File.directory?(fixtures)
    step "harness: seed already built (#{fixtures})"
  else
    sh!(File.join(HARNESS, "bin", "seed"), env: env) # long: builds the Rails reference image + fixtures
  end
end
