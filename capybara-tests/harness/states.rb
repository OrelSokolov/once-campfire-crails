# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "labels"

module Parity
  # One programmatic login per role; the session cookie is stored and injected
  # into fresh browser sessions, keeping us far below the login rate limit.
  module States
    ROLES = { david: EMAILS.fetch(:david), jason: EMAILS.fetch(:jason),
              kevin: EMAILS.fetch(:kevin), lou: EMAILS.fetch(:loner) }.freeze

    @cookies = {}

    def self.cookies_for(role, base_url)
      jar = @cookies[role]
      return jar if jar && session_valid?(jar, base_url)

      @cookies[role] = login(ROLES.fetch(role), base_url)
    end

    # A cached cookie dies server-side when its session is terminated (e.g. a
    # sign-out test). Revalidate cheaply; re-login only when actually dead.
    def self.session_valid?(jar, base_url)
      uri = URI("#{base_url}/users/me/sidebar")
      response = Net::HTTP.start(uri.host, uri.port) do |http|
        http.get(uri.path, "cookie" => jar.map { |name, value| "#{name}=#{value}" }.join("; "))
      end
      response.is_a?(Net::HTTPSuccess)
    end

    def self.login(email, base_url)
      uri = URI("#{base_url}/session/new")
      jar = {}
      Net::HTTP.start(uri.host, uri.port) do |http|
        response = http.get(uri.path)
        response.get_fields("set-cookie")&.each { |line| jar[session_cookie_name(line)] = session_cookie_value(line) }
        csrf = response.body[/name="csrf-token" content="([^"]+)"/, 1]
        request = Net::HTTP::Post.new("/session")
        request.set_form_data({ "email_address" => email, "password" => Parity::PASSWORD, "authenticity_token" => csrf.to_s })
        request["cookie"] = jar.map { |name, value| "#{name}=#{value}" }.join("; ")
        response = http.request(request)
        response.get_fields("set-cookie")&.each { |line| jar[session_cookie_name(line)] = session_cookie_value(line) }
        raise "login failed for #{email}: #{response.code}" unless response.is_a?(Net::HTTPRedirection)
      end
      jar
    end

    def self.session_cookie_name(line)
      line[/\A([^=]+)=/, 1]
    end

    def self.session_cookie_value(line)
      line[/\A[^=]+=([^;]+)/, 1]
    end

    # Inject a role's cookies into the current capybara session.
    def self.sign_in_as(page, role, base_url)
      page.reset_session if page.respond_to?(:reset_session)
      cookies_for(role, base_url).each do |name, value|
        page.driver.set_cookie(name, value, url: base_url)
      end
    end
  end
end
