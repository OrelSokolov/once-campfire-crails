# Smoke для ChatLayout.editable_body (messages/edit rich_text_area
# value): байтовое сравнение с эталонами, снятыми с Rails-оракула
# (once-campfire/test/helpers/print_editable_body_test.rb,
# RAILS_ENV=test). Юзер David (id 127326141, без bio, updated_at
# 2026-10-27T22:54:30Z) и секрет тестового окружения оракула — тогда
# sgid и аватар-токен в упоминании совпадают байт в байт.
#
#   SECRET_KEY_BASE=adaff11824b297a48812a3b63d0305987cf859f2300a03e85bd79b68c894ca89dc6718a8eadad72cbc6bab358801fbfe586eb062a400b4ee27ace07998673e2f \
#     crystal run script/editable_body_smoke.cr
require "../src/app_boot_models"
require "../app/helpers/html_sanitizer"
require "../app/helpers/rich_text_helper"
require "../app/helpers/drop_target_helper"
require "../app/helpers/chat_layout"
require "../app/helpers/translations_helper"
require "../app/helpers/boosts_erb"
require "../app/helpers/messages_erb"
require "../app/helpers/chat_erb"
require "../config/routes"

DB_PATH = "#{__DIR__}/../tmp/editable-smoke.sqlite3"
File.delete(DB_PATH) rescue nil
ActiveRecord::Base.establish_connection("sqlite3://#{DB_PATH}")
CRails.application.initialize!

now = Time.utc
ActiveRecord::Base.connection.exec(
  "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, created_at TIMESTAMP NOT NULL, " \
  "updated_at TIMESTAMP NOT NULL, role INTEGER NOT NULL DEFAULT 0, email_address VARCHAR, " \
  "password_digest VARCHAR, bio TEXT, bot_token VARCHAR, status INTEGER NOT NULL DEFAULT 0)")
ActiveRecord::Base.connection.exec(
  "INSERT INTO users (id, name, bio, email_address, created_at, updated_at) VALUES (?, ?, NULL, 'd@example.com', ?, ?)",
  127_326_141_i64, "David", now, Time.utc(2026, 10, 27, 22, 54, 30))

SGID = "eyJfcmFpbHMiOnsiZGF0YSI6ImdpZDovL2NhbXBmaXJlL1VzZXIvMTI3MzI2MTQxP2V4cGlyZXNfaW4iLCJwdXIiOiJhdHRhY2hhYmxlIn19--082228f4b70f77cb820c63706cfabe81fe717228"
AVATAR_TOKEN = "eyJfcmFpbHMiOnsiZGF0YSI6MTI3MzI2MTQxLCJwdXIiOiJ1c2VyL2F2YXRhciJ9fQ--8f07f011f92d5836e1f8c69d847f5ca0415518a89c77709a87f3412ade8260ac"

# mention content: users/_mention перерендереный to_editor_attachment!
# (сырой, с \n на конце), затем Nokogiri-экранирование атрибута (& и ").
MENTION_CONTENT = %(<span class=&quot;mention&quot; sgid=&quot;#{SGID}&quot;) +
                  %(<a title=&quot;David&quot; class=&quot;btn avatar&quot; data-turbo-frame=&quot;_top&quot; href=&quot;/users/127326141&quot;) +
                  %(><img aria-hidden=&quot;true&quot; src=&quot;/users/#{AVATAR_TOKEN}/avatar?v=20261027225430&quot; width=&quot;48&quot; height=&quot;48&quot; /></a> ) +
                  %(David</span>\n)

cases = [] of {String, String, String}

# 1: Trix-era OG embed, детали в атрибутах узла
cases << {"og-attrs",
  %(<div>https://example.com/ <action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" url="https://example.com/image.png" href="https://example.com/" filename="Example title" caption="Example description"></action-text-attachment></div>),
  %(<div>https://example.com/ <action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" url="https://example.com/image.png" href="https://example.com/" filename="Example title" caption="Example description" content="<figure class=&quot;attachment attachment--content attachment--og&quot;>\n  \n    <div class=&quot;og-embed gap &quot;>\n      <div class=&quot;og-embed__content&quot;>\n        <div class=&quot;og-embed__title&quot;>\n          <a href=&quot;https://example.com/&quot;>Example title</a>\n        </div>\n        <div class=&quot;og-embed__description&quot;>Example description</div>\n      </div>\n        <div class=&quot;og-embed__image&quot;>\n          <img src=&quot;https://example.com/image.png&quot; class=&quot;image center&quot; alt=&quot;&quot;>\n        </div>\n    </div>\n  \n</figure>"></action-text-attachment></div>)}

# 2: lexxy OG embed, детали в content-разметке (рукописная, враждебная)
cases << {"og-content",
  %(<p><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" url="https://example.com/image.png" content="<actiontext-opengraph-embed data-controller=&quot;pwn&quot; data-action=&quot;click-&gt;pwn#run&quot;> <div class=&quot;og-embed&quot;><div class=&quot;og-embed__title&quot;><a href=&quot;/rooms/1&quot;>Free cookies</a></div> <div class=&quot;og-embed__image&quot;><img src=&quot;/rooms/1/avatar&quot; data-action=&quot;load-&gt;pwn#run&quot;></div></div> </actiontext-opengraph-embed>"></action-text-attachment></p>),
  %(<p><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" url="https://example.com/image.png" content="<figure class=&quot;attachment attachment--content attachment--og&quot;>\n  \n    <div class=&quot;og-embed gap &quot;>\n      <div class=&quot;og-embed__content&quot;>\n        <div class=&quot;og-embed__title&quot;>\n          Free cookies\n        </div>\n        <div class=&quot;og-embed__description&quot;></div>\n      </div>\n    </div>\n  \n</figure>"></action-text-attachment></p>)}

# 3: mention, отредактированный под Trix (generic content-type)
cases << {"mention-trix",
  %(<div>Hey <action-text-attachment sgid="#{SGID}" content-type="application/octet-stream"></action-text-attachment></div>),
  %(<div>Hey <action-text-attachment sgid="#{SGID}" content-type="application/vnd.campfire.mention" content="#{MENTION_CONTENT}"></action-text-attachment></div>)}

# 4: lexxy-сериализация mention (sgid, content, content-type) — content
# переезжает в конец
cases << {"mention-lexxy",
  %(<div><action-text-attachment sgid="#{SGID}" content="<span class=&quot;mention&quot; sgid=&quot;#{SGID}&quot;>old</span>" content-type="application/vnd.campfire.mention"></action-text-attachment></div>),
  %(<div><action-text-attachment sgid="#{SGID}" content-type="application/vnd.campfire.mention" content="#{MENTION_CONTENT}"></action-text-attachment></div>)}

# 5: plain body — без изменений (плюс strip хвостовых \n, как
# Fragment.wrap)
cases << {"plain", %(<p>Plain text</p>\n), %(<p>Plain text</p>)}

# 6: twitter avatar OG embed
cases << {"og-twitter",
  %(<div><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" url="https://pbs.twimg.com/profile_images/123/x.png" href="https://twitter.com/jason/status/1" filename="A tweet" caption="Tweet text"></action-text-attachment></div>),
  %(<div><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" url="https://pbs.twimg.com/profile_images/123/x.png" href="https://twitter.com/jason/status/1" filename="A tweet" caption="Tweet text" content="<figure class=&quot;attachment attachment--content attachment--og&quot;>\n  \n    <div class=&quot;og-embed gap og-embed--twitter-avatar&quot;>\n      <div class=&quot;og-embed__content&quot;>\n        <div class=&quot;og-embed__title&quot;>\n          <a href=&quot;https://twitter.com/jason/status/1&quot;>A tweet</a>\n        </div>\n        <div class=&quot;og-embed__description&quot;>Tweet text</div>\n      </div>\n        <div class=&quot;og-embed__image&quot;>\n          <img src=&quot;https://pbs.twimg.com/profile_images/123/x.png&quot; class=&quot;image center&quot; alt=&quot;&quot;>\n        </div>\n    </div>\n  \n</figure>"></action-text-attachment></div>)}

# 7: OG embed без валидного href — заголовок без анкора, &amp; из
# атрибута не дублируется
cases << {"og-nohref",
  %(<div><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" filename="Local &amp; strange" caption="Desc"></action-text-attachment></div>),
  %(<div><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" filename="Local &amp; strange" caption="Desc" content="<figure class=&quot;attachment attachment--content attachment--og&quot;>\n  \n    <div class=&quot;og-embed gap &quot;>\n      <div class=&quot;og-embed__content&quot;>\n        <div class=&quot;og-embed__title&quot;>\n          Local &amp;amp; strange\n        </div>\n        <div class=&quot;og-embed__description&quot;>Desc</div>\n      </div>\n    </div>\n  \n</figure>"></action-text-attachment></div>)}

# 8: неизвестный attachable (не OG, не User) — узел без изменений
# (оракул здесь падает NoMethodError — см. known-gaps)
cases << {"unknown",
  %(<div><action-text-attachment sgid="bogus" content-type="application/octet-stream" url="https://example.com/x.png"></action-text-attachment></div>),
  %(<div><action-text-attachment sgid="bogus" content-type="application/octet-stream" url="https://example.com/x.png"></action-text-attachment></div>)}

failures = 0
cases.each do |label, input, expected|
  got = ChatLayout.editable_body(input)
  if got == expected
    puts "#{label}: OK"
  else
    failures += 1
    puts "#{label}: FAIL\n  expected: #{expected.inspect}\n  got:      #{got.inspect}"
  end
end

exit(failures.zero? ? 0 : 1)
