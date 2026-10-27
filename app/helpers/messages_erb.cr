# MessagesERB: ERB rendering context for messages/_message + _actions +
# _presentation + _unrenderable — the per-message DOM of the
# fragment-cache hot path. The oracle renders the same partials off the
# message's associations; the port preloads room/creator/attachment/boost
# snapshots in bulk (see ChatLayout.messages_to), so the partial locals
# carry them alongside the message (BoostsERB precedent). The
# presentation (attachment/sound/text) and the message--emoji class are
# derived once per instance — the same values ChatLayout.message_dom
# computed inline before the extraction.
class MessagesERB
  include ActionView::Helpers
  include CRails::Routes::UrlHelpers
  # Block capture form of turbo_frame_tag (turbo_cr shard).
  include Turbo::FramesHelper

  def initialize(message : Message, room : Room, creator : User?,
                 attachment : ChatLayout::Attachment?,
                 boosts : Array(ChatLayout::BoostEntry), base_url : String)
    @message = message
    @room = room
    @creator = creator
    @attachment = attachment
    @boosts = boosts
    @base_url = base_url
    @created = message.created_at || Time.utc
    # message--emoji: plain_text_body.all_emoji? — a sound ("/play …") is
    # not an emoji message; the class is derived from the body text, not
    # from the player markup.
    @sound = attachment ? nil : ChatLayout.message_sound(message.body.to_s)
    @presentation_html = if attachment
      ChatLayout.attachment_presentation(attachment)
    elsif sound = @sound
      ChatLayout.sound_presentation(sound)
    else
      ChatLayout.text_presentation(message.body.to_s)
    end
    @emoji = (attachment.nil? && @sound.nil? && ChatLayout.all_emoji?(@presentation_html)) ? " message--emoji" : ""
  end

  # Entry point (ChatLayout.message_dom): the placeholder partial when the
  # record's author is deleted (oracle's message_tag rescue →
  # messages/unrenderable), otherwise the message partial.
  def render_message : String
    if (creator = @creator)
      render(partial: "messages/message", locals: {
        "message"    => @message,
        "room"       => @room,
        "creator"    => creator,
        "attachment" => @attachment,
      }).to_s
    else
      render(partial: "messages/unrenderable").to_s
    end
  end

  # Propshaft-style manifest resolution (same override as ChatERB).
  def image_tag(source : String, **opts) : ERB::SafeString
    ::ActionView::Helpers::AssetTagHelper.image_tag(
      ChatLayout.asset(source), __av_opts_to_h(opts))
  end

  # Oracle MessagesHelper#message_tag: the message div. The data-*
  # attribute order is the oracle's raw byte order (client-message-id
  # last); the tag builder emits kwargs order, so the port builds the
  # open tag literally.
  def message_tag(message : Message, &)
    ERB::SafeString.new(message_open_tag(message) + capture { yield }.to_s + "</div>\n")
  end

  # local_datetime (gem): a <time> filled in client-side by LocalTime.
  def local_datetime_tag(time : Time?, style : Symbol = :time) : ERB::SafeString
    target = style == :date ? "date" : "time"
    ERB::SafeString.new(
      %(<time datetime="#{(time || @created).to_rfc3339}" data-local-time-target="#{target}"></time>))
  end

  # Oracle MessagesHelper#message_timestamp.
  def message_timestamp(message : Message, **options) : ERB::SafeString
    cls = __av_opts_to_h(options)["class"]?.to_s
    cls_part = cls.empty? ? "" : %( class="#{cls}")
    ERB::SafeString.new(
      %(<time#{cls_part} datetime="#{@created.to_rfc3339}" data-local-time-target="time"></time>))
  end

  # Oracle Users::AvatarsHelper#avatar_tag: link + image.
  def avatar_tag(creator : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.avatar_link(creator))
  end

  # Oracle MessagesHelper#message_author_title: [name, bio].join(" – ").
  def message_author_title(creator : User) : String
    ChatLayout.user_title(creator.name, creator.bio)
  end

  def room_display_name(room : Room) : String
    ChatLayout.room_display_name(room)
  end

  # Oracle MessagesHelper#message_presentation: attachment / sound / text.
  # Text is wrapped in the lexxy-content wrapper
  # (layouts/action_text/contents/_content), attachments are not.
  def message_presentation(message : Message) : ERB::SafeString
    if @attachment.nil? && @sound.nil?
      ERB::SafeString.new(%(<div class="lexxy-content">\n) + @presentation_html +
        (@presentation_html.ends_with?("\n") ? "" : "\n") + %(</div>\n))
    else
      ERB::SafeString.new(@presentation_html + "\n")
    end
  end

  def room_at_message_path(room : Room, message : Message) : String
    ChatLayout.route_path("room_at_message", room.id, message.id)
  end

  # The actions' Copy-link URL is absolute (oracle: room_at_message_url).
  def room_at_message_url(room : Room, message : Message) : String
    path = room_at_message_path(room, message)
    @base_url.empty? ? path : "#{@base_url}#{path}"
  end

  def message_boosts_path(message : Message) : String
    ChatLayout.route_path("message_boosts", message.id.not_nil!)
  end

  def new_message_boost_path(message : Message) : String
    "#{message_boosts_path(message)}/new"
  end

  def edit_room_message_path(room : Room, message : Message) : String
    ChatLayout.route_path("edit_room_message", room.id, message.id.not_nil!)
  end

  # ActiveStorage blob path of the attachment snapshot
  # (rails_blob_path attachment, only_path: true).
  def attachment_blob_path(attachment : ChatLayout::Attachment) : String
    ChatLayout.blob_url(attachment)
  end

  def attachment_download_path(attachment : ChatLayout::Attachment) : String
    "#{attachment_blob_path(attachment)}?disposition=attachment"
  end

  # messages/boosts/_boosts via BoostsERB — no trailing \n: the template's
  # own newline after the tag supplies it (as _message.html.erb does).
  def render_boosts(message : Message) : ERB::SafeString
    BoostsERB.new.render(partial: "messages/boosts/boosts",
      locals: {"message_id" => message.id.not_nil!, "boosts" => @boosts})
  end

  private def message_open_tag(message : Message) : String
    mid = message.id.not_nil!
    updated = message.updated_at || @created
    %(<div id="message_#{mid}" class="message#{@emoji}" data-controller="reply" ) +
      %(data-user-id="#{message.creator_id}" data-message-id="#{mid}" ) +
      %(data-message-timestamp="#{@created.to_fs(:epoch)}" data-message-updated-at="#{updated.to_fs(:epoch)}" ) +
      %(data-sort-value="#{@created.to_fs(:epoch)}" data-messages-target="message" ) +
      %(data-search-results-target="message" data-refresh-room-target="message" ) +
      %(data-reply-composer-outlet="#composer" data-client-message-id="#{HTML.escape(message.client_message_id.to_s)}">)
  end

  compile_partials({
    "messages/message"       => {path: "app/views/messages/_message.html.erb",
                                 locals: {"message"    => Message,
                                          "room"       => Room,
                                          "creator"    => User,
                                          "attachment" => ChatLayout::Attachment?}},
    "messages/actions"       => {path: "app/views/messages/_actions.html.erb",
                                 locals: {"message"    => Message,
                                          "room"       => Room,
                                          "attachment" => ChatLayout::Attachment?,
                                          "url"        => String}},
    "messages/presentation"  => {path: "app/views/messages/_presentation.html.erb",
                                 locals: {"message" => Message}},
    "messages/unrenderable"  => {path: "app/views/messages/_unrenderable.html.erb",
                                 locals: {} of String => Nil},
  })
end
