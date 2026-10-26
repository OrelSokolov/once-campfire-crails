require "./authentication/session_lookup"

module Authentication
  include SessionLookup

  # class_methods (authentication.rb:14-20): allow_unauthenticated_access /
  # allow_bot_access as skip_before_action wrappers. `{{ options.double_splat }}`
  # reifies the resolved named tuple — a raw `**options` would leak the
  # unresolved Var into the callee's positional splat.
  macro allow_unauthenticated_access(**options)
    {% if options.empty? %}
      skip_before_action :require_authentication
    {% else %}
      skip_before_action :require_authentication, {{ options.double_splat }}
    {% end %}
  end

  macro allow_bot_access(**options)
    {% if options.empty? %}
      skip_before_action :deny_bots
    {% else %}
      skip_before_action :deny_bots, {{ options.double_splat }}
    {% end %}
  end

  @identity_entry : Campfire::IdentityCache::Entry? = nil
  @identity_checked : Bool = false
  @authenticated_by : ActiveSupport::StringInquirer? = nil

  # Only a successfully authenticated bot key disables CSRF protection
  # (protect_from_forgery unless: -> { authenticated_by.bot_key? }).
  def bot_request? : Bool
    return false unless key = params["bot_key"]?
    !User.authenticate_bot(key.to_s).nil?
  end

  # The oracle renders forms without embedded authenticity tokens;
  # verification is header-only (Sec-Fetch-Site), so the field stays empty.
  protected def __csrf_token_field(action : String, method : String) : String
    ""
  end

  def current_session : Session?
    return nil unless (entry = find_session_by_cookie)
    @identity_checked = true
    @identity_entry = entry
    set_authenticated_by(:session)
    Current.session = @identity_entry.try(&.session)
    Current.user = @identity_entry.try(&.user)
    @identity_entry.try(&.session)
  end

  def current_user : User?
    current_session unless @identity_checked
    @identity_entry.try(&.user)
  end

  # Bang variant (Ruby-style): the authenticated user or a raise.
  def current_user! : User
    current_user!
  end

  def require_authentication : Nil
    bot_authentication
    redirect_to new_session_url unless current_user
  end

  # authentication.rb:38-44 — a valid bot_key authenticates as the bot
  # user (tracked through authenticated_by, like the oracle).
  def bot_authentication : Nil
    if (key = params["bot_key"]?.try(&.to_s.presence)) &&
       (bot = User.authenticate_bot(key.strip))
      Current.user = bot
      set_authenticated_by(:bot_key)
    end
  end

  # authentication.rb:101-103 — bots authenticated via bot_key are forbidden
  # on regular controllers.
  def deny_bots : Nil
    head :forbidden if authenticated_by.bot_key?
  end

  def set_authenticated_by(method : Symbol) : Nil
    @authenticated_by = method.to_s.inquiry
  end

  def authenticated_by : ActiveSupport::StringInquirer
    @authenticated_by ||= "".inquiry
  end

  def start_new_session_for(user : User) : Nil
    session = Session.start!(user, request.headers["User-Agent"]?, remote_ip)
    Current.session = session
    Current.user = user
    set_authenticated_by(:session)
    cookies.signed.permanent[:session_token] = { value: session.token!, httponly: true, same_site: :lax }
  end

  # X-Forwarded-For is honored only when the socket peer is a trusted proxy,
  # mirroring ActionDispatch::RemoteIp.
  def remote_ip : String?
    socket_ip = case addr = request.remote_address
                when Socket::IPAddress then addr.address.to_s
                else nil
                end
    if (fwd = request.headers["X-Forwarded-For"]?) &&
       (client = fwd.split(',').first?.try(&.strip)) && !client.empty? &&
       socket_ip.try { |ip| trusted_proxy?(ip) }
      return client
    end
    socket_ip || request.headers["Remote-Addr"]? || "127.0.0.1"
  end

  private def trusted_proxy?(ip : String) : Bool
    !Opengraph.public_ip?(ip)
  end

  # Rails signed_id via MessageVerifier with the "active_record/signed_id" key;
  # Rails 8.1 urlsafe envelope without padding.
  def generate_signed_id(user_id : Int64, purpose : String, expires_at : Time? = nil) : String
    CRails.application.message_verifier("active_record/signed_id", url_safe: true)
      .generate(user_id, purpose: purpose, expires_at: expires_at)
  end

  def verify_signed_id(token : String, purpose : String) : Int64?
    # sha256 first, sha1 fallback for legacy tokens; verifiers are memoized
    # on CRails.application.
    value = CRails.application.message_verifier("active_record/signed_id",
      url_safe: true).verified_any(token, purpose: purpose)
    if value.nil?
      value = CRails.application.message_verifier("active_record/signed_id",
        digest: :sha1, url_safe: true).verified_any(token, purpose: purpose)
    end
    if (raw = value.try(&.as_i?)) || (raw = value.try(&.as_s?.try(&.to_i64?)))
      return raw.to_i64
    end
    nil
  end

  def origin : String
    host = request.headers["Host"]? || "localhost"
    scheme = request.headers["X-Forwarded-Proto"]?
      .try(&.split(',').first?.try(&.strip)) || "http"
    "#{scheme}://#{host}"
  end
end
