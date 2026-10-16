# frozen_string_literal: true

# ————— compose: reference stand from GitHub (Dockerfile.github) —————

COMPOSE_FILE = File.join(REPO_ROOT, "docker-compose.github.yml").freeze

def compose!(*args)
  sh!("docker", "compose", "-f", COMPOSE_FILE, *args)
end

namespace :compose do
  desc "Build the reference image (toolchain only; app is built at container start)"
  task :build do
    compose!("build")
  end

  desc "Rebuild and start the reference stand on 127.0.0.1:5555 (clone/build/migrate/assets run at container start)"
  task :up do
    compose!("build")
    compose!("up")
    port = File.read(COMPOSE_FILE)[/HTTP_PORT:\s*"(\d+)"/, 1] || "5555"
    puts "Reference stand is starting: http://127.0.0.1:#{port}"
    puts "First start compiles in-container (~minutes): docker logs -f once-campfire-reference"
  end

  desc "Stop the reference stand (volumes kept; RESET=1 also drops the DB volumes)"
  task :down do
    args = ENV["RESET"] == "1" ? %w[down -v] : %w[down]
    compose!(*args)
  end

  desc "Remove old untagged images from previous reference builds (matched by label)"
  task :clean do
    ids = `docker images --filter dangling=true -q`.split.uniq
    ours = ids.select do |id|
      `docker inspect --format '{{json .Config.Labels}}' #{id} 2>/dev/null`
        .include?('"once-campfire-crails.stand":"reference"')
    end
    if ours.empty?
      puts "No old reference images to remove"
    else
      puts "Removing old reference images: #{ours.join(' ')}"
      sh!("docker", "rmi", *ours)
    end
  end
end
