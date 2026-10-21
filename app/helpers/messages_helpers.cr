# MessagesHelpers — ERB-хелперы app/views/messages/{show,edit}.html.erb:
# DOM сообщения, presentation вложения, путь сообщения, страница истории.
# Включается в MessagesController; общий icon — ViewHelpers.
module MessagesHelpers
  # create.turbo_stream.erb: append DOM сообщения в контейнер комнаты
  # (тег + хвостовой \n файла).
  def append_message_stream(room : Room, message_html : String) : String
    %(<turbo-stream action="append" target="messages_#{room.dom_id}"><template>) +
      message_html + %(</template></turbo-stream>\n)
  end

  # show.html.erb: DOM сообщения (тот же message_dom, что в комнате).
  def message_dom : ERB::SafeString
    message = self.message.not_nil!
    attachment = ChatLayout.attachments_for([message.id.not_nil!])[message.id.not_nil!]?
    ERB::SafeString.new(ChatLayout.message_dom(message, room.not_nil!,
      User.find?(message.creator_id.not_nil!), attachment, base_url: origin))
  end

  # edit.html.erb: presentation вложения (attachment-ветка).
  def attachment_html : ERB::SafeString
    ERB::SafeString.new(ChatLayout.attachment_presentation(attachment.not_nil!))
  end

  # messages.eta (референс): каждая запись — тот же DOM, что в комнате
  # (message_dom: <div data-message-id=...> + turbo-frame + </turbo-frame>
  # </div> closure); минимальный <article> не проходит route-contract-v1
  # loadgen'а (<div ... data-message-id> + </turbo-frame></div>$).
  # Список — через fragment-кэш (было User.find?/rich_text на каждое
  # сообщение): хиты без SQL, авторы промахов — одним IN-запросом.
  # Rails messages/index.html.erb (layout false): голая коллекция
  # message-партиалов — без doctype/обёрток; JS-пагинатор вставляет
  # ответ как фрагмент прямо в .messages.
  def messages_page_html(room : Room, messages : Array(Message),
                         epoch : String) : String
    String.build do |io|
      ChatLayout.messages_to(io, messages, epoch, room, origin)
    end
  end
end
