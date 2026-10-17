# frozen_string_literal: true

require "fileutils"
require "open3"
require "json"
require "chunky_png"

module Parity
  # Compares artifacts/<baseline>/ against artifacts/<target>/:
  # PNG byte equality first (same renderer ⇒ byte-identical at zero diff), then
  # a chunky_png per-pixel ratio against MAX_DIFF_RATIO; HTML via diff -u.
  # Writes artifacts/compare/report.html and exits non-zero on any failure.
  module Compare
    module_function

    def walk(dir, prefix = "")
      Dir.children(dir).flat_map do |entry|
        path = File.join(dir, entry)
        rel = prefix.empty? ? entry : File.join(prefix, entry)
        File.directory?(path) ? walk(path, rel) : [rel]
      end.sort
    rescue Errno::ENOENT
      []
    end

    def run(baseline = ENV.fetch("PARITY_BASELINE", "rails"), target = ENV.fetch("TARGET", "crails"))
      max_ratio = Float(ENV.fetch("MAX_DIFF_RATIO", "0.002"))
      suite = File.expand_path("..", __dir__)
      base_dir = File.join(suite, "artifacts", baseline)
      target_dir = File.join(suite, "artifacts", target)
      out_dir = File.join(suite, "artifacts", "compare")
      FileUtils.mkdir_p(out_dir)

      rels = (walk(base_dir) | walk(target_dir)).sort
      results = rels.map do |rel|
        if !File.exist?(File.join(base_dir, rel))
          { rel:, kind: kind(rel), pass: false, missing: "baseline" }
        elsif !File.exist?(File.join(target_dir, rel))
          { rel:, kind: kind(rel), pass: false, missing: "target" }
        else
          compare_one(base_dir, target_dir, rel, out_dir, max_ratio)
        end
      end

      png = results.select { |r| r[:kind] == "png" }
      html = results.select { |r| r[:kind] == "html" }
      failed = results.reject { |r| r[:pass] }
      summary = { baseline:, target:, max_ratio:,
                  png_total: png.size, png_passed: png.count { |r| r[:pass] },
                  html_total: html.size, html_passed: html.count { |r| r[:pass] },
                  missing: results.count { |r| r[:missing] }, failed: failed.size }
      File.write(File.join(out_dir, "summary.json"), JSON.pretty_generate({ summary:, results: }))
      require_relative "report"
      File.write(File.join(out_dir, "report.html"), Parity::Report.render(summary:, results:, baseline:, target:))
      puts "\nparity #{baseline} vs #{target}: png #{summary[:png_passed]}/#{summary[:png_total]}, " \
           "html #{summary[:html_passed]}/#{summary[:html_total]}" +
           (summary[:missing].positive? ? ", missing #{summary[:missing]}" : "") +
           " → artifacts/compare/report.html"
      failed.first(40).each do |item|
        detail = item[:missing] ? "(missing in #{item[:missing]})" : ratio_detail(item)
        puts "  FAIL #{item[:rel]} #{detail}"
      end
      failed.empty?
    end

    def kind(rel)
      File.extname(rel).delete_prefix(".")
    end

    def ratio_detail(item)
      return px_detail(item[:ratio] * 100) if item[:ratio]
      return "(#{item[:diff_lines]} diff lines)" if item[:diff_lines]
      item[:error] ? "(#{item[:error]})" : ""
    end

    # Severity coloring for pixel-diff percentages: <1% white (default),
    # >=1% yellow, >=5% red, >=10% bold inverted red (clearly bad).
    def px_severity(pct)
      return :worst if pct >= 10
      return :bad if pct >= 5
      return :warn if pct >= 1
      :ok
    end

    ANSI = { ok: "\e[0m", warn: "\e[33m", bad: "\e[31m", worst: "\e[1;97;41m" }.freeze

    def px_detail(pct)
      text = format("(%.3f%% px)", pct)
      return text unless $stdout.tty?
      "#{ANSI.fetch(px_severity(pct))}#{text}\e[0m"
    end

    def compare_one(base_dir, target_dir, rel, out_dir, max_ratio)
      case kind(rel)
      when "png" then compare_png(base_dir, target_dir, rel, out_dir, max_ratio)
      when "html" then compare_html(base_dir, target_dir, rel, out_dir)
      else { rel:, kind: kind(rel), pass: true }
      end
    end

    def compare_png(base_dir, target_dir, rel, out_dir, max_ratio)
      base_file = File.join(base_dir, rel)
      target_file = File.join(target_dir, rel)
      return { rel:, kind: "png", pass: true, ratio: 0.0 } if File.binread(base_file) == File.binread(target_file)

      # Some .png-named artifacts are downloaded assets, not screenshots
      # (e.g. the deterministic avatar endpoint serves SVG). Pixel math only
      # applies to real PNGs; anything else falls back to byte equality.
      # (.b: binread is ASCII-8BIT; == on incompatible encodings is false
      # even for identical bytes.)
      png_signature = "\x89PNG\r\n\x1a\n".b
      unless File.binread(base_file, 8) == png_signature && File.binread(target_file, 8) == png_signature
        return { rel:, kind: "png", pass: false, error: "non-PNG bytes differ" }
      end

      base_png = ChunkyPNG::Image.from_file(base_file)
      target_png = ChunkyPNG::Image.from_file(target_file)
      if base_png.dimension != target_png.dimension
        return { rel:, kind: "png", pass: false, error: "size #{base_png.width}x#{base_png.height} vs #{target_png.width}x#{target_png.height}" }
      end
      diff = ChunkyPNG::Image.new(base_png.width, base_png.height, ChunkyPNG::Color::WHITE)
      diff_pixels = 0
      base_png.height.times do |y|
        base_png.width.times do |x|
          next if base_png[x, y] == target_png[x, y]

          diff_pixels += 1
          diff[x, y] = ChunkyPNG::Color.rgb(255, 0, 0)
        end
      end
      total = base_png.width * base_png.height
      ratio = diff_pixels.to_f / total
      pass = ratio <= max_ratio
      if !pass || ENV["PARITY_DIFF_IMAGES"] == "all"
        diff_path = File.join(out_dir, rel.sub(/\.png\z/, ".diff.png"))
        FileUtils.mkdir_p(File.dirname(diff_path))
        diff.save(diff_path, :fast_rgba)
      end
      { rel:, kind: "png", pass:, ratio:, diff_pixels:, total: }
    end

    def compare_html(base_dir, target_dir, rel, out_dir)
      base_text = File.read(File.join(base_dir, rel))
      target_text = File.read(File.join(target_dir, rel))
      return { rel:, kind: "html", pass: true } if base_text == target_text

      diff_text, = Open3.capture2("diff", "-u", File.join(base_dir, rel), File.join(target_dir, rel))
      diff_path = File.join(out_dir, rel.sub(/\.html\z/, ".diff.txt"))
      FileUtils.mkdir_p(File.dirname(diff_path))
      File.write(diff_path, diff_text)
      { rel:, kind: "html", pass: false, diff_lines: diff_text.lines.count }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit Parity::Compare.run(ARGV[0], ARGV[1])
end
