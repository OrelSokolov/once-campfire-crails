# frozen_string_literal: true

# ————— Glob-safe aliases —————
# Bash expands `rake benchmark[crails]` into the existing benchmarks/
# directory (the class [crails] contains 's') — rake silently treats it as
# a file task and exits without doing work. Same awaits rails/express. Quoted
# arguments (`rake 'benchmark[crails]'`) work, but colon-style aliases that
# the glob cannot touch are more convenient:

%w[download build clean rebuild verify benchmark].each do |base|
  namespace base do
    APP_ORDER.each do |app|
      desc "#{base}: only #{app} (bracket-free alias)"
      task(app) { Rake::Task[base].invoke(app) }
    end
  end
end
