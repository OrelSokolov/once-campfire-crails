# Reproducer: scheduler resumes a dead fiber whose stack was recycled by
# Fiber::StackPool -> garbage context restored -> SIGSEGV.
# Crystal 1.21.1, build: crystal build --release -Dwithout_mt -o repro repro.cr
# (needs the sqlite3 shard: crystal deps add sqlite3)
#
# Pattern: HTTP server with churn of clients that drop connections mid-
# response (request fibers die on IO errors), every request does pooled
# SQLite work (WAL + PRAGMA data_version + INSERT) plus a second database
# (jobs-style queue), one long-lived sleeper per "connection".

require "http/server"
require "socket"
require "sqlite3"

def db(path, wal = true)
  d = DB.open("sqlite3://#{path}?max_pool_size=5&max_idle_pool_size=5")
  d.setup_connection do |conn|
    conn.exec("PRAGMA busy_timeout=10000")
    conn.exec("PRAGMA journal_mode=#{wal ? "WAL" : "DELETE"}")
    conn.exec("PRAGMA synchronous=NORMAL")
  end
  d
end

main = db("#{Dir.tempdir}/repro-main-#{Process.pid}.sqlite3")
main.exec("CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, v TEXT)")
main.exec("INSERT INTO t(v) VALUES ('x')")

jobs = db("#{Dir.tempdir}/repro-jobs-#{Process.pid}.sqlite3")
jobs.exec("CREATE TABLE IF NOT EXISTS j(id INTEGER PRIMARY KEY, v TEXT)")

n = Atomic(Int32).new(0)

server = HTTP::Server.new do |context|
  i = n.add(1)
  # epoch-style pragma + read on the main db (pool checkout)
  main.query("PRAGMA data_version") do |rs|
    rs.each { rs.read(Int64) }
  end
  main.query("SELECT id, v FROM t LIMIT 20") { |rs| rs.each { rs.read(Int64); rs.read(String) } }
  # write + second db enqueue (two pools in one request)
  main.exec("INSERT INTO t(v) VALUES (?)", "y#{i}")
  jobs.exec("INSERT INTO j(v) VALUES (?)", "job#{i}")
  body = String.build(32 * 1024) { |io| 500.times { |k| io << k << ',' } }
  context.response << body
end

address = server.bind_tcp("127.0.0.1", 0)
spawn { server.listen }
Fiber.yield

spawn do # abusive clients: open, partial request / early close mid-response
  loop do
    30.times do
      spawn do
        sock = TCPSocket.new("127.0.0.1", address.port)
        sock << "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        sock.read_timeout = rand(0.001..0.005).seconds
        buf = Bytes.new(4096)
        while sock.read(buf) > 0
          break if rand < 0.3 # abandon mid-response
        end
        sock.close
      rescue ex
      end
    end
    sleep 1.millisecond
  end
end

spawn do # GC pressure
  loop do
    10_000.times { |i| s = "x#{i}" * 30 }
    Fiber.yield
  end
end

sleep
