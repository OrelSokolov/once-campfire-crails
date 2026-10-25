require "./application_record"
require "uuid"
# Message bodies live in ActionText (action_text_rich_texts) and are
# mirrored into the FTS5 message_search_index by the reference app;
# the seed database carries both.
class Message < ApplicationRecord
  belongs_to :room
  belongs_to :creator, class_name: "User", default: -> { Current.user }
  has_many :boosts, foreign_key: "message_id"

  # The oracle's after_save :record_creation / after_create_commit push live in
  # MessageCreator instead: the index insert needs the pre-computed plain text
  # of the request's body_html (not reachable from the model), and job
  # enqueueing must stay outside the production transaction (see
  # message_creator.cr and notes/style-parity.md).
  before_create -> { self.client_message_id ||= UUID.random.to_s } # Bots don't care

  has_rich_text :body
  preloadable_attachment :attachment

  scope :ordered, -> { order(:created_at) }
  scope :with_creator, -> { preload(creator: :avatar_attachment) }
  scope :with_attachment_details, -> {
    with_rich_text_body_and_embeds.with_attached_attachment
  }
  scope :with_boosts, -> { includes(boosts: { booster: :avatar_attachment }) }
  scope :with_presentation, -> { with_creator.with_attachment_details.with_boosts.preload(:room) }

  # Search-index copy (FTS5, rowid = message id) — the authoritative body
  # text for search results and contract word content.
  def indexed_body : String?
    row = ActiveRecord::Base.connection.query_one?(
      "SELECT body FROM message_search_index WHERE rowid = ?", id,
      as: String)
    row
  end
end
