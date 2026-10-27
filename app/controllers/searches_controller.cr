class SearchesController < ApplicationController

  # Getters expose the ivars to the SearchesHelper ERB helpers.
  attr_reader user : User? = nil
  attr_reader query : String = ""
  attr_reader messages : Array(Message) = [] of Message
  attr_reader recents : Array(String) = [] of String
  attr_reader epoch : String = ""
  @return_room : Int64 = 1_i64

  # Search nav partials, rendered through the SearchesHelper wrappers.
  compile_partials({
    "searches/nav" => {path: "app/views/searches/_nav.html.erb",
                       locals: {"query" => String, "count" => Int32,
                                "recents" => Array(String)}},
    "searches/recent_searches" => {path: "app/views/searches/_recent_searches.html.erb",
                                   locals: {"recents" => Array(String)}},
  }, dedent: true)

  def index
    user = current_user!

    # Whole-page cache (like rooms#show): the key includes the query (?q=...),
    # invalidated by the shared DB epoch.
    page = cache_page("searches#show", user.id) do
      query = params["q"]?.to_s.strip

      messages = if query.empty?
        [] of Message
      else
        # Same shape as the harness's seed SQL: messages visible to the user,
        # newest 100 matches by id, displayed in id order.
        Message.where(
          %(id IN (SELECT m.id FROM messages m
                   JOIN message_search_index idx ON idx.rowid = m.id
                   JOIN memberships mm ON mm.room_id = m.room_id
                   WHERE mm.user_id = ? AND message_search_index MATCH ?
                   ORDER BY m.id DESC LIMIT 100)),
          user.id!, Message::Searchable.match_terms(query))
          .order("id ASC").to_a
      end

      # Recent searches: the latest 10 queries.
      recents = ActiveRecord::Base.connection.query_all(
        "SELECT query FROM searches WHERE user_id = ? ORDER BY updated_at DESC LIMIT 10",
        args: [user.id!], as: String)

      # Return room for the composer (the Exit search arrow).
      return_room = (user.memberships.map(&.room_id!).min? ||
                    Room.visible_for(user).order("id").first.try(&.id!) || 1).to_i64

      # Results come from a fragment cache; rooms and authors of cache misses are
      # fetched with one IN-query per entity.
      @user = user
      @query = query
      @messages = messages
      @recents = recents
      @return_room = return_room
      @epoch = db_epoch
      # page_open/page_close register the layout inputs during the template
      # render; the shell comes from __render_layout (layouts/application).
      # The template renders before the layout block — a nested render
      # inside would clobber the layout's shared output buffer.
      content = __render_view("index").to_s
      Campfire::ResponseCache::Page.new(__render_layout { content }.to_s)
    end
    send_page(page)
  end

  def create
    user = current_user!
    query = params["q"]?.to_s.strip
    unless query.empty?
      now = Time.utc
      Search.new(user_id: user.id!, query: query,
        created_at: now, updated_at: now).save!
    end
    redirect_to searches_url(q: query)
  end

  def clear
    user = current_user!
    ActiveRecord::Base.connection.exec(
      "DELETE FROM searches WHERE user_id = ?", user.id!)
    redirect_to searches_url
  end

end
