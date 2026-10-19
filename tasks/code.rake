# frozen_string_literal: true

# ————— code: снапшоты исходников для twinshot-группы code —————
#
# «Генерация» — это копия файла в общий формат: у пути снимается последнее
# расширение и добавляется .code.txt, чтобы деревья оракала (Rails,
# once-campfire/) и текущего проекта (crails, корень) выровнялись путь-в-путь:
#
#   app/models/user.rb / app/models/user.cr          → app/models/user.code.txt
#   app/views/x/y.html.erb / app/views/x/y.html.ecr  → app/views/x/y.html.code.txt
#   Gemfile / Gemfile                                → Gemfile.code.txt
#
# twinshot сравнивает .code.txt построчно (txt-адаптер) и в отчёте видно,
# какая доля файлов проекта совпадает с Rails-оригиналом по стилю.
#
# Источник файлов — git ls-files: дерево вне .gitignore (у оракала свой
# git-репозиторий в once-campfire/, crails-корень его исключает).

CODE_DIR = File.join(REPO_ROOT, "code-artifacts")

# Двоичные расширения: построчное сравнение бессмысленно — в группу не идут.
CODE_SKIP_EXT = %w[
  png jpg jpeg gif webp ico woff woff2 ttf otf eot
  mp3 ogg wav mp4 zip gz xz sqlite3 dwarf
].to_h { |e| [".#{e}", true] }.freeze

def code_snapshot(side, src_dir)
  files = capture!("git", "-C", src_dir, "ls-files").lines.map(&:strip).reject(&:empty?)
  out = File.join(CODE_DIR, side)
  FileUtils.remove_entry(out) if File.exist?(out)
  skipped_binary = 0
  files.each do |rel|
    ext = File.extname(rel).downcase
    if CODE_SKIP_EXT[ext]
      skipped_binary += 1
      next
    end
    target = File.join(out, ext.empty? ? "#{rel}.code.txt" : "#{rel.delete_suffix(ext)}.code.txt")
    # Коллизия после снятия расширения (Gemfile/Gemfile.lock, Dockerfile/
    # Dockerfile.github): проигравший сохраняет полное имя — Gemfile.lock.code.txt.
    # Правило одинаково на обеих сторонах, выравнивание деревьев не страдает.
    if File.exist?(target)
      warn "code: rename collision — #{rel} keeps full name (#{target} already taken)"
      target = File.join(out, "#{rel}.code.txt")
    end
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(File.join(src_dir, rel), target)
  end
  step "code:#{side}: #{files.size - skipped_binary} files → #{out} (#{skipped_binary} binary skipped)"
end

namespace :code do
  desc "Snapshot Rails oracle sources (once-campfire/) into the twinshot group code"
  task :oracle do
    code_snapshot("oracle", File.join(REPO_ROOT, "once-campfire"))
  end

  desc "Snapshot crails sources (project root) into the twinshot group code"
  task :current do
    code_snapshot("current", REPO_ROOT)
  end
end

desc "Snapshot both sides of the twinshot code group (oracle + current)"
task code: %i[code:oracle code:current]
