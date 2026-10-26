# BoostsERB: ERB rendering context for messages/boosts/_boosts +
# _boost — the boost strip under each message (fragment-cache hot
# path). The oracle renders the same partials off the message.boosts
# association; the port preloads BoostEntry snapshots in one JOIN (see
# ChatLayout.boosts_for), so the partial locals are the snapshot plus
# the message id.
class BoostsERB
  include ActionView::Helpers
  include CRails::Routes::UrlHelpers
  # Block capture form of turbo_frame_tag (turbo_cr shard).
  include Turbo::FramesHelper

  # Propshaft-style manifest resolution (same override as ChatERB).
  def image_tag(source : String, **opts) : ERB::SafeString
    ::ActionView::Helpers::AssetTagHelper.image_tag(
      ChatLayout.asset(source), __av_opts_to_h(opts))
  end

  # Oracle Users::AvatarsHelper#avatar_tag: link + image. The snapshot
  # carries the booster fields instead of a User record; an explicit
  # aria: (the boost label) replaces the default hidden (Ruby hash
  # semantics — the raw oracle bytes show aria-label without
  # aria-hidden on boost avatars).
  def avatar_tag(b : ChatLayout::BoostEntry, **options) : ERB::SafeString
    link_to(user_path(b.booster_id),
      title: ChatLayout.user_title(b.booster_name, b.booster_bio),
      class: "btn avatar", data: {turbo_frame: "_top"}) do
      opts = {"size" => 48} of String => ActionView::Helpers::TagHelper::AttrVal
      __av_opts_to_h(options).each { |k, v| opts[k] = v }
      ::ActionView::Helpers::AssetTagHelper.image_tag(
        ChatLayout.fresh_user_avatar_path(b.booster_id, b.booster_updated_at), opts)
    end
  end

  # Oracle: class: ["txt-small", { "txt-medium": boost.content.all_emoji? }]
  def boost_span_class(b : ChatLayout::BoostEntry) : String
    ChatLayout.all_emoji?(b.content) ? "txt-small txt-medium" : "txt-small"
  end

  compile_partials({
    "messages/boosts/boosts" => {path: "app/views/messages/boosts/_boosts.html.erb",
                                 locals: {"message_id" => Int64,
                                          "boosts"    => Array(ChatLayout::BoostEntry)}},
    "messages/boosts/boost"  => {path: "app/views/messages/boosts/_boost.html.erb",
                                 locals: {"boost" => ChatLayout::BoostEntry}},
  })
end
