# Webhook público que recebe mensagens de entrada do provedor (Evolution/WAHA/
# UazAPI) e cria a conversa/mensagem no inbox vinculado. Sem autenticação.
class Kanban::ProviderWebhooksController < ActionController::API
  def receive
    inst = Kanban::ConnectionInstance.find_by(instance_name: params[:instance_name])
    return head(:not_found) if inst.nil? || inst.inbox_id.nil?

    # Perna SECUNDÁRIA da caixa híbrida: existe só para ENVIAR mensagem de sessão
    # sem cobrança. Quem recebe é o webhook oficial da Meta — processar entrada aqui
    # faria a mesma mensagem virar duas conversas para o mesmo contato.
    #
    # A trava é explícita, e não implícita pelo `native_chatwoot`: sem ela, marcar a
    # conexão como não-nativa faria o fluxo cair no caminho de baixo, que CRIA a
    # conversa — o oposto do que se quer.
    # [3b] Por padrão a perna secundária é rejeitada. EXCEÇÃO: se "gerenciar grupos"
    # (hybrid_groups) estiver ligado na caixa híbrida, deixa passar as mensagens de
    # GRUPO (@g.us) — a Cloud oficial não faz grupo, então essa é a única forma de
    # gerenciar grupos numa caixa híbrida. O 1:1 continua rejeitado (vem pela oficial).
    if inst.meta.is_a?(Hash) && inst.meta['hybrid_role'] == 'secondary'
      return head(:ok) unless hybrid_secondary_group_inbound?(inst, params.to_unsafe_h)
    end

    # astracall: as mensagens já entram via integração nativa /chatwoot; aqui só
    # APRENDEMOS o mapeamento LID↔contato (p/ ligações de entrada caírem no ticket certo)
    if inst.provider == 'astracall'
      receber_astracall(inst, params.to_unsafe_h)
      return head :ok
    end

    payload = params.to_unsafe_h

    # A Evolution também envia a atualização do status da mensagem separada do
    # evento de criação (messages.upsert). Sem tratar messages.update, o Chatwoot
    # registra o envio como aceito, mas nunca recebe o recibo DELIVERY_ACK/READ e
    # o tique azul não aparece. O evento é terminal aqui para não tentar parseá-lo
    # como uma nova mensagem.
    if inst.provider == 'evolution' && handle_evolution_message_status(inst, payload)
      return head :ok
    end

    # Reação (Evolution/WAHA): esses provedores mandam um webhook secundário só p/
    # eventos de reação; casamos por source_id e gravamos content_attributes.reactions.
    rx = extract_provider_reaction(inst, payload)
    if rx
      apply_provider_reaction(inst, rx)
      return head :ok
    end

    # Provedores com integração nativa entregam as MENSAGENS pela ponte /chatwoot —
    # não recriar aqui (senão duplica). Só o webhook de reação acima e o NOME do
    # contato (política única, issue #51) são tratados.
    if inst.meta.is_a?(Hash) && inst.meta['native_chatwoot']
      sync_native_contact_name(inst, payload)
      return head :ok
    end

    data = parse_incoming(inst, payload)
    return head(:ok) if data.nil?

    # #147: mensagem que o ATENDENTE respondeu pelo PRÓPRIO celular (fromMe) numa caixa
    # de sessão não-nativa (uazapi). Antes era descartada aqui e o atendimento ficava
    # sem registro do que foi dito por fora. Agora vira bolha de SAÍDA na mesma conversa
    # (o listener não reenvia porque já tem source_id). Grupo/sem-telefone: fora por ora.
    if data[:from_me]
      process_outgoing(inst, data) unless data[:is_group] || data[:phone].blank?
      return head(:ok)
    end

    # GRUPO: o JID do grupo (18 díg) não passa na validação e164 de telefone —
    # criamos a conversa como GRUPO (source_id = JID) igual ao AstraCall, exceto
    # quando "ignorar grupos" está ligado (meta).
    if data[:is_group]
      return head(:ok) if inst.meta.to_h['ignore_groups']

      process_group_incoming(inst, data)
      return head :ok
    end

    return head(:ok) if data[:phone].blank?

    process_incoming(inst, data)
    head :ok
  rescue StandardError => e
    Rails.logger.error("[Kanban::ProviderWebhook] #{e.message}")
    head :ok
  end

  private

  # [3b] A perna secundária do híbrido pode RECEBER grupos quando "gerenciar grupos"
  # está ligado na caixa. Só passa mensagem de GRUPO (@g.us); 1:1 continua bloqueado.
  def hybrid_secondary_group_inbound?(inst, payload)
    ch = inst.inbox&.channel
    return false unless ch.is_a?(Channel::Whatsapp)
    return false unless ActiveModel::Type::Boolean.new.cast(ch.provider_config.to_h['hybrid_groups'])
    return false unless payload['event'] == 'message'

    d = payload['data'] || {}
    ActiveModel::Type::Boolean.new.cast(d['isGroup']) || d['chat'].to_s.end_with?('@g.us')
  end

  # Recibo de status do AstraCall (WaCalls) via webhook da sessão:
  #   { event:'receipt', data:{ ids:[wa_msg_id,...], type:'' | 'read' | 'played', ... } }
  # type vazio = ENTREGUE (delivered); 'read'/'played' = LIDO (read). Casa cada id
  # com a msg de SAÍDA por source_id e atualiza via StatusUpdateService (que dispara
  # broadcast pra UI + o sync entregue/lido do Disparador). Antes disso a msg de saída
  # ficava eternamente em 'sent' (um check) porque ninguém processava o recibo.
  def receber_astracall(inst, payload)
    case payload['event']
    when 'reaction'
      handle_reaction(inst, payload)
    when 'receipt'
      # Recibo de entrega/leitura do WhatsApp (o WaCalls manda por aqui, NÃO pelo
      # /message_status). Sem tratar isso, a msg de saída travava em 1 check.
      handle_astracall_receipt(inst, payload)
    else
      # Edição feita pelo CLIENTE: o WhatsApp REUSA o id da mensagem original,
      # então o evento não é mensagem nova — tratar antes de tudo e sair.
      return if handle_astracall_edit(inst, payload)
      # "Apagar para todos" por um participante (revoke): some pra nós também. Tratar
      # ANTES do handler de grupo (que descarta evento sem texto).
      return if handle_astracall_revoke(inst, payload)

      capturar_referral_astracall(inst, payload)
      learn_astracall_lid(inst, payload)
      # Nome do contato: a ponte nativa só grava o nome quando ELA cria o contato,
      # então quando quem inicia a conversa somos nós o contato fica com o telefone
      # no lugar do nome. O webhook da sessão traz o pushName — a política decide.
      sync_astracall_contact_name(inst, payload)
      # Localização (pin de mapa): a ponte nativa /chatwoot não encaminha location
      # (só texto/mídia), então o pin somia. Aqui lemos o raw.locationMessage do
      # webhook da sessão e criamos a mensagem com anexo de localização, ESPELHANDO
      # o attach_location nativo. Só anexa a uma conversa EXISTENTE (não cria) — zero
      # risco de duplicar o ticket 1:1 que a ponte cria.
      handle_astracall_location(inst, payload)
      # Mensagens de GRUPO não entram pela integração nativa /chatwoot (ela ignora
      # @g.us), então criamos a conversa/mensagem aqui a partir do webhook da sessão.
      handle_astracall_group_message(inst, payload)
    end
  end

  # Cria a mensagem de LOCALIZAÇÃO recebida (1:1) do AstraCall. Ver comentário na
  # chamada. Seguro/aditivo: dedup por source_id e SÓ anexa a conversa já existente.
  def handle_astracall_location(inst, payload)
    return unless payload['event'] == 'message'

    d = payload['data'] || {}
    return if ActiveModel::Type::Boolean.new.cast(d['fromMe'])
    return if ActiveModel::Type::Boolean.new.cast(d['isGroup']) # grupo: fora do escopo

    loc = extrair_localizacao_astracall(d)
    return if loc.nil?

    source_id = d['id'].to_s
    if source_id.present? && Message.where(inbox_id: inst.inbox_id).exists?(source_id: source_id)
      return
    end

    # O remetente pode vir como @lid (identificador de privacidade do WhatsApp), que
    # NÃO bate com o contato (a ponte chaveia por <telefone>@s.whatsapp.net + phone_number,
    # com contact_inbox.source_id = UUID). O evento traz o telefone REAL em
    # chatPhone/senderPhone — resolvemos por ele e montamos o identifier equivalente.
    jid = (d['chat'].presence || d['sender']).to_s
    phone = jid_phone(jid).presence ||
            d['chatPhone'].to_s.gsub(/\D/, '').presence ||
            d['senderPhone'].to_s.gsub(/\D/, '').presence
    identifier = phone.present? ? "#{phone}@s.whatsapp.net" : jid

    # Contato duplicado do mesmo número é comum (a ponte pode criar mais de um). Junta
    # TODOS os candidatos (por identifier OU telefone) e pega a conversa NÃO-resolvida
    # mais recente entre eles — é onde as demais mensagens do cliente estão caindo. Não
    # cria conversa nova (zero risco de duplicar o ticket que a ponte já mantém).
    acc = inst.inbox.account
    conds = ['contacts.identifier = ?']
    vals = [identifier]
    if phone.present?
      conds << 'contacts.phone_number IN (?)'
      vals << ["+#{phone}", phone]
    end
    cand_ids = acc.contacts.where(conds.join(' OR '), *vals).pluck(:id)
    ci_ids = inst.inbox.contact_inboxes.where(contact_id: cand_ids).pluck(:id)
    conv = inst.inbox.conversations.where(contact_inbox_id: ci_ids).where.not(status: :resolved).order(last_activity_at: :desc).first ||
           inst.inbox.conversations.where(contact_inbox_id: ci_ids).order(last_activity_at: :desc).first
    if conv.nil?
      Rails.logger.info("[Kanban::ProviderWebhook] astracall location: sem conversa p/ jid=#{jid} phone=#{phone.inspect} (pin ignorado)")
      return
    end

    criar_mensagem_localizacao_astracall(conv, conv.contact, loc, source_id)
    Rails.logger.info("[Kanban::ProviderWebhook] astracall location criada conv=#{conv.id} phone=#{phone.inspect}")
  rescue StandardError => e
    Rails.logger.warn("[Kanban::ProviderWebhook] astracall location: #{e.class} #{e.message}")
  end

  # Extrai { lat, long, name, address } do evento. Prioriza o raw.locationMessage do
  # Baileys (degreesLatitude/degreesLongitude); cai para um campo `location` já
  # normalizado se o provedor mandar assim. nil se não for localização.
  def extrair_localizacao_astracall(d)
    lm = d.dig('raw', 'locationMessage') || d.dig('raw', 'message', 'locationMessage')
    if lm.is_a?(Hash) && (lm['degreesLatitude'].present? || lm['degreesLongitude'].present?)
      return { lat: lm['degreesLatitude'], long: lm['degreesLongitude'], name: lm['name'], address: lm['address'] }
    end

    l = d['location']
    if l.is_a?(Hash) && (l['latitude'].present? || l['degreesLatitude'].present?)
      return { lat: l['latitude'] || l['degreesLatitude'], long: l['longitude'] || l['degreesLongitude'],
               name: l['name'], address: l['address'] }
    end
    nil
  end

  # Espelha o attach_location nativo (incoming_message_base_service): mensagem de
  # entrada + anexo file_type=location com coordinates_lat/long e fallback_title.
  def criar_mensagem_localizacao_astracall(conv, contact, loc, source_id)
    nome = [loc[:name].presence, loc[:address].presence].compact.join(', ')[0, 255]
    # Constrói mensagem + anexo ATOMICAMENTE (new + save!): se criar a mensagem primeiro,
    # o dispatch pro front (websocket) sai SEM o anexo → cai na bolha de Texto vazia. E o
    # roteamento da bolha de Localização (Message.vue) exige SEM content (o nome vai no
    # fallback_title, como o attach_location nativo). Por isso content fica nil.
    msg = conv.messages.new(
      account_id: conv.account_id, inbox_id: conv.inbox_id,
      message_type: :incoming, content_type: 'text',
      source_id: source_id.presence, sender: contact
    )
    msg.attachments.new(
      account_id: conv.account_id,
      file_type: :location,
      coordinates_lat: loc[:lat], coordinates_long: loc[:long],
      fallback_title: nome.presence
    )
    msg.save!
    msg
  end

  # Cliente editou a mensagem que mandou. Sem isto o ticket ficava com o texto
  # ANTIGO para sempre — o atendente lia uma coisa e o cliente via outra.
  #
  # A original é achada por `editedId`, NUNCA por `id`: no evento real de edição
  # (que vem criptografado e é decifrado no servidor do provedor) o `id` é um id
  # NOVO do próprio evento — usar ele não acharia nada. O contrato inicial dizia
  # que os dois seriam iguais; foi corrigido depois do caso 3EB09D… ≠ 3EB063….
  def handle_astracall_edit(inst, payload)
    return false unless payload['event'] == 'message'

    d = payload['data'] || {}
    return false unless ActiveModel::Type::Boolean.new.cast(d['edited'])

    original = d['editedId'].to_s
    if original.blank?
      Rails.logger.warn("[Kanban::ProviderWebhook] edicao sem editedId (id=#{d['id']}) — nada a atualizar")
      return true
    end

    aplicar_edicao(inst, original, texto_da_edicao(d))
    true
  rescue StandardError => e
    Rails.logger.warn("[Kanban::ProviderWebhook] astracall edit: #{e.message}")
    true
  end

  # De onde tirar o texto novo. O contrato manda em `data.text`, mas no evento REAL
  # observado (26/08, evento 3EB0C1116C46B698C1AF) ele chega VAZIO com
  # `type: "unknown"` — o provedor decifra a edição e monta `edited`/`editedId`,
  # mas ainda não preenche o texto do topo. O `raw` já vem DECODIFICADO, com o
  # conteúdo dentro de protocolMessage → editedMessage, às vezes em DUAS camadas.
  # Então: usa o topo quando vier, e desce no raw quando não vier.
  NIVEIS_EDIT = 6

  def texto_da_edicao(dados)
    direto = dados['text'].to_s
    return direto if direto.present?

    no = dados.dig('raw', 'protocolMessage')
    NIVEIS_EDIT.times do
      editada = no.is_a?(Hash) ? no['editedMessage'] : nil
      break unless editada.is_a?(Hash)

      texto = editada['conversation'].presence || editada.dig('extendedTextMessage', 'text').presence
      return texto if texto.present?

      no = editada['protocolMessage']
    end
    ''
  end

  SUFIXO_EDICAO = "\n\n✏️ *Editado no WhatsApp*".freeze

  # Mesma representação que o WAHA usa (caixa 69): a mensagem ORIGINAL fica
  # intacta e a edição entra como uma mensagem NOVA, com o texto corrigido e
  # CITANDO a original (in_reply_to). Assim o atendente vê a correção chegar na
  # linha do tempo, no lugar certo, e continua enxergando o que foi dito antes —
  # três edições viram três mensagens, todas citando a mesma original.
  def aplicar_edicao(inst, source_id, texto)
    return if source_id.blank? || texto.blank?

    escopo = Message.where(inbox_id: inst.inbox_id)
    original = escopo.find_by(source_id: source_id) || escopo.find_by(source_id: "WAID:#{source_id}")
    return if original.nil?

    Message.create!(
      account_id: original.account_id, inbox_id: original.inbox_id,
      conversation_id: original.conversation_id, message_type: :incoming,
      sender_type: original.sender_type, sender_id: original.sender_id,
      content: "#{texto}#{SUFIXO_EDICAO}", content_type: 'text',
      content_attributes: { 'in_reply_to' => original.id, 'in_reply_to_external_id' => nil,
                            'kanban_edited' => true }
    )
  end

  # "Apagar para todos" (revoke) por um PARTICIPANTE do grupo (ou pelo cliente no 1:1):
  # o Baileys entrega um protocolMessage tipo REVOKE apontando (via key) o id da msg
  # revogada. Antes isto era ignorado e a msg PERSISTIA pra nós; agora marcamos a nossa
  # cópia como apagada (some pra nós, igual ao WhatsApp). Espelha handle_astracall_edit.
  def handle_astracall_revoke(inst, payload)
    return false unless payload['event'] == 'message'

    d = payload['data'] || {}
    revoked = extrair_id_revoke(d)
    if revoked.blank?
      # Diagnóstico: se veio um protocolMessage SEM editedMessage que não casou como
      # revoke, registra a estrutura p/ calibrar o formato real do provedor.
      pm = d.dig('raw', 'protocolMessage') || d.dig('raw', 'message', 'protocolMessage')
      if pm.is_a?(Hash) && pm['editedMessage'].blank?
        Rails.logger.info("[Kanban::ProviderWebhook] possível revoke não reconhecido: #{pm.to_json[0, 600]}")
      end
      return false
    end

    aplicar_revoke(inst, revoked)
    Rails.logger.info("[Kanban::ProviderWebhook] astracall revoke aplicado id=#{revoked}")
    true
  rescue StandardError => e
    Rails.logger.warn("[Kanban::ProviderWebhook] astracall revoke: #{e.message}")
    true
  end

  # Id da mensagem revogada. Baileys: protocolMessage.type REVOKE (0) + key.id. Alguns
  # provedores normalizam em campos de topo — cobrimos os dois. protocolMessage COM
  # editedMessage é EDIÇÃO (não revoke) e é ignorado aqui.
  def extrair_id_revoke(dados)
    pm = dados.dig('raw', 'protocolMessage') || dados.dig('raw', 'message', 'protocolMessage')
    if pm.is_a?(Hash) && pm['editedMessage'].blank?
      # type REVOKE do Baileys = 0 (inteiro) ou string "REVOKE"; to_s cobre os dois
      # (0 -> "0") sem quebrar em nil/string.
      revoke = %w[0 REVOKE].include?(pm['type'].to_s.strip.upcase)
      if revoke
        id = pm.dig('key', 'id').presence || pm['stanzaId'].presence || pm['stanzaID'].presence
        return id.to_s if id.present?
      end
    end
    (dados['revokedId'] || dados['revokeId'] || dados['revoked_message_id']).to_s.presence
  end

  # Marca a nossa cópia como apagada: content vazio + content_attributes.deleted (o
  # front renderiza "mensagem apagada"). O marcador kanban_revoked_external impede o
  # initializer de RESTAURAR o texto original (queremos que suma, não que preserve).
  # 1:1 e grupo. Não propaga nada de volta ao provedor (é msg de ENTRADA).
  def aplicar_revoke(inst, source_id)
    escopo = Message.where(inbox_id: inst.inbox_id)
    msg = escopo.find_by(source_id: source_id) || escopo.find_by(source_id: "WAID:#{source_id}")
    return if msg.nil?

    ca = msg.content_attributes
    return if ca.is_a?(Hash) && ca['deleted']

    novo = (ca.is_a?(Hash) ? ca : {}).merge('deleted' => true, 'kanban_revoked_external' => true)
    msg.update!(content: '', content_attributes: novo)
  end

  # Origem de anúncio (Click to WhatsApp). A ponte nativa não conhece esse campo,
  # então capturamos do webhook da sessão e gravamos no MESMO formato da API
  # oficial — é de lá que o Meta CAPI lê o ctwa_clid para atribuir a campanha.
  def capturar_referral_astracall(inst, payload)
    return unless payload['event'] == 'message'

    d = payload['data'] || {}
    ref = d['referral']
    return unless ref.is_a?(Hash) && ref.present?

    Kanban::AstracallReferralJob.perform_later(inst.inbox_id, d['id'].to_s, normalizar_referral(ref))
  rescue StandardError => e
    Rails.logger.warn("[Kanban::ProviderWebhook] astracall referral: #{e.message}")
  end

  def normalizar_referral(ref)
    { 'ctwa_clid' => ref['ctwaClid'], 'source_id' => ref['sourceId'],
      'source_url' => ref['sourceUrl'], 'source_type' => ref['sourceType'],
      'headline' => ref['title'], 'body' => ref['body'], 'ref' => ref['ref'] }.compact_blank
  end

  def handle_astracall_receipt(inst, payload)
    data = payload['data']
    return unless data.is_a?(Hash)

    status = astracall_receipt_status(data['type'])
    return if status.nil?

    Array(data['ids']).each do |sid|
      sid = sid.to_s.strip
      next if sid.blank?

      msg = Message.where(inbox_id: inst.inbox_id, message_type: Message.message_types[:outgoing])
                   .find_by(source_id: sid)
      next if msg.nil?

      Messages::StatusUpdateService.new(msg, status).perform
    end
  rescue StandardError => e
    Rails.logger.warn("[Kanban::ProviderWebhook] astracall receipt: #{e.message}")
  end

  # Mapeia o tipo de recibo do WaCalls -> status do Chatwoot. 'read-self' (o próprio
  # remetente leu em outro aparelho) e tipos desconhecidos são ignorados (nil).
  def astracall_receipt_status(type)
    case type.to_s.strip.downcase
    when '', 'delivery', 'delivered' then 'delivered'
    when 'read', 'played' then 'read'
    end
  end

  # A Evolution envia recibos de mensagem em `messages.update`, com um ou mais
  # itens { key: { id, fromMe }, update: { status } }. Só atualizamos mensagens de
  # saída desta caixa: recibos de entrada não são o status das respostas do agente.
  def handle_evolution_message_status(inst, payload)
    event = payload['event'].to_s.downcase.tr('_', '.')
    return false unless event == 'messages.update'

    Array.wrap(payload['data']).each do |item|
      next unless item.is_a?(Hash)

      key = item['key'].is_a?(Hash) ? item['key'] : {}
      next unless ActiveModel::Type::Boolean.new.cast(key['fromMe'])

      source_id = key['id'].to_s.strip
      next if source_id.blank?

      status = evolution_message_status(item.dig('update', 'status') || item['status'])
      next if status.nil?

      msg = find_message_by_source(inst.inbox_id, source_id)
      next if msg.nil? || !msg.outgoing?

      Messages::StatusUpdateService.new(msg, status).perform
    end
    true
  rescue StandardError => e
    Rails.logger.warn("[Kanban::ProviderWebhook] evolution message status: #{e.class} #{e.message}")
    true
  end

  # Baileys/Evolution: SERVER_ACK=2, DELIVERY_ACK=3, READ=4, PLAYED=5.
  # Eventos podem vir tanto com o nome como com o enum numérico.
  def evolution_message_status(value)
    case value.to_s.strip.upcase
    when '3', 'DELIVERY_ACK', 'DELIVERED' then 'delivered'
    when '4', '5', 'READ', 'PLAYED' then 'read'
    end
  end

  # Trava ATÔMICA de entrega (cross-process) via Redis SETNX+TTL. O provedor
  # reentrega a mesma mensagem (id igual) e o índice `messages.source_id` NÃO é
  # único, então o `exists?(source_id:)` sozinho corre risco de CORRIDA (duas
  # entregas concorrentes passam o exists? antes de qualquer uma commitar e ambas
  # criam → mensagem duplicada, sobretudo em GRUPO). Só a 1ª entrega de cada
  # (inbox, msg_id) segue; as reentregas dentro do TTL são descartadas. Se o Redis
  # falhar, não bloqueia (fail-open) — o exists? ainda cobre reentregas lentas.
  def claim_delivery(inbox_id, msg_id)
    return true if msg_id.blank?

    Redis::Alfred.set("kanban:pwh:#{inbox_id}:#{msg_id}", 1, nx: true, ex: 300).present?
  rescue StandardError => e
    Rails.logger.warn("[Kanban::ProviderWebhook] claim_delivery: #{e.message}")
    true
  end

  # Assinatura de conteúdo de uma mensagem de GRUPO — ESTÁVEL entre reentregas do
  # provedor mesmo quando o id muda (ou vem vazio). Usa grupo + remetente + texto +
  # timestamp DA MENSAGEM (não o de recebimento), que é o mesmo em todas as cópias
  # da mesma mensagem. Duas mensagens realmente diferentes (texto/remetente/segundo
  # distintos) geram assinaturas distintas — não corre risco de descartar msg legítima.
  def group_dedup_sig(chat, data, text)
    ts = (data['timestamp'] || data['messageTimestamp'] || data.dig('raw', 'messageTimestamp')).to_s
    sender = (data['sender'] || data['participant'] || data['author']).to_s
    "sig:#{Digest::MD5.hexdigest("#{chat}|#{sender}|#{text}|#{ts}")}"
  end

  # reação recebida (cliente reagiu no zap): acha a msg pelo source_id (=messageId
  # do WhatsApp) e grava em content_attributes.reactions. removed=true retira.
  # Salvar dispara message.updated → o dashboard mostra/atualiza o emoji na hora.
  def handle_reaction(inst, payload)
    # os campos vêm aninhados em data (fallback p/ top-level por robustez)
    d = payload['data'].is_a?(Hash) ? payload['data'] : payload
    source_id = d['messageId'].to_s
    return if source_id.blank?

    msg = Message.where(inbox_id: inst.inbox_id).find_by(source_id: source_id)
    if msg.nil?
      Rails.logger.info("[Kanban::ProviderWebhook] reaction: msg não achada p/ source_id=#{source_id}")
      return
    end

    emoji = d['emoji'].to_s
    removed = [true, 'true'].include?(d['removed'])
    reactor = d['reactorPhone'].presence || d['reactor'].to_s
    name = d['reactorName'].to_s

    ca = msg.content_attributes || {}
    list = Array(ca['reactions']).map { |r| r.is_a?(Hash) ? r.stringify_keys : r }
    # 1 reação por reator (do lado do cliente, from_me:false)
    list.reject! { |r| !r['from_me'] && r['reactor'].to_s == reactor.to_s }
    list << { 'emoji' => emoji, 'reactor' => reactor.to_s, 'name' => name, 'from_me' => false } unless removed || emoji.blank?
    ca['reactions'] = list
    msg.update!(content_attributes: ca)
  rescue StandardError => e
    Rails.logger.warn("[Kanban::ProviderWebhook] reaction: #{e.message}")
  end

  # === Reações de Evolution/WAHA (entrada) ===
  # Normaliza o evento de reação do provedor para { target_id, emoji, reactor, name, from_me }.
  def extract_provider_reaction(inst, payload)
    case inst.provider
    when 'evolution', 'evolution-go' then evolution_reaction(payload)
    when 'waha' then waha_reaction(payload)
    end
  end

  # Evolution: reação vem num MESSAGES_UPSERT com data.message.reactionMessage
  # ({ key: {id: <id da msg reagida>}, text: <emoji> }). text vazio = reação removida.
  def evolution_reaction(payload)
    d = payload['data'] || {}
    rm = d.dig('message', 'reactionMessage')
    return nil unless rm.is_a?(Hash)

    target = rm.dig('key', 'id').to_s
    return nil if target.blank?

    reactor = (d.dig('key', 'participant').presence || d.dig('key', 'remoteJid')).to_s.split('@').first.to_s.gsub(/\D/, '')
    { target_id: target, emoji: rm['text'].to_s, reactor: reactor,
      name: d['pushName'].to_s, from_me: d.dig('key', 'fromMe') == true }
  end

  # WAHA: evento `message.reaction` com payload.reaction = { text, messageId }.
  def waha_reaction(payload)
    return nil unless payload['event'].to_s == 'message.reaction'

    p = payload['payload'] || {}
    r = p['reaction'] || {}
    target = r['messageId'].to_s
    return nil if target.blank?

    { target_id: target, emoji: r['text'].to_s,
      reactor: p['from'].to_s.split('@').first.to_s.gsub(/\D/, ''),
      name: p.dig('_data', 'notifyName').to_s, from_me: p['fromMe'] == true }
  end

  # acha a msg pelo source_id (normalizando o prefixo WAID: da integração nativa da
  # Evolution) e grava a reação. Salvar dispara message.updated → badge na hora.
  def apply_provider_reaction(inst, rx)
    msg = find_message_by_source(inst.inbox_id, rx[:target_id])
    if msg.nil?
      Rails.logger.info("[Kanban::ProviderWebhook] reação: msg não achada p/ id=#{rx[:target_id]}")
      return
    end

    removed = rx[:emoji].blank?
    from_me = rx[:from_me]
    ca = msg.content_attributes || {}
    list = Array(ca['reactions']).map { |r| r.is_a?(Hash) ? r.stringify_keys : r }
    # 1 reação por reator+lado
    list.reject! { |r| r['from_me'] == from_me && r['reactor'].to_s == rx[:reactor].to_s }
    list << { 'emoji' => rx[:emoji], 'reactor' => rx[:reactor].to_s, 'name' => rx[:name].to_s, 'from_me' => from_me } unless removed
    ca['reactions'] = list
    msg.update!(content_attributes: ca)
  rescue StandardError => e
    Rails.logger.warn("[Kanban::ProviderWebhook] apply_provider_reaction: #{e.message}")
  end

  # source_id pode estar cru (id) ou com o prefixo WAID: (Evolution nativo) — tenta ambos
  def find_message_by_source(inbox_id, raw_id)
    scope = Message.where(inbox_id: inbox_id)
    scope.find_by(source_id: raw_id) ||
      scope.find_by(source_id: "WAID:#{raw_id}") ||
      (raw_id.start_with?('WAID:') ? scope.find_by(source_id: raw_id.sub(/\AWAID:/, '')) : nil)
  end

  # extrai o LID do remetente de um evento `message` do AstraCall e dispara o
  # aprendizado do mapeamento LID→contato (correlação com a msg nativa por texto)
  def learn_astracall_lid(inst, payload)
    return unless payload['event'] == 'message'

    d = payload['data'] || {}
    return if d['fromMe']

    sender = d['sender'].to_s
    return unless sender.include?('@lid')

    lid = sender.split('@').first.to_s.gsub(/\D/, '')
    text = d['text'].to_s
    return if lid.blank? || text.blank?

    Kanban::AstracallLidLearnJob.set(wait: 5.seconds).perform_later(inst.id, lid, text)
  end

  # Cria conversa/mensagem para mensagens de GRUPO (@g.us) do AstraCall. A integração
  # nativa /chatwoot ignora grupos, então tratamos aqui. O contato é o GRUPO (source_id
  # = JID do grupo). Prefixamos o nome do remetente no conteúdo p/ o agente saber quem
  # falou. Dedup por source_id (id da msg) evita duplicidade em reenvios.
  def handle_astracall_group_message(inst, payload)
    return unless payload['event'] == 'message'

    d = payload['data'] || {}
    return unless d['isGroup']
    return if d['fromMe']
    # Respeita "ignorar grupos" (persistido em inst.meta ao salvar a config da conexão).
    return if inst.meta.to_h['ignore_groups']

    chat = d['chat'].to_s
    return unless chat.end_with?('@g.us')

    # A integração NATIVA do AstraCall PASSOU A entregar mensagens de grupo (cria a
    # conversa E a mensagem via /chatwoot). Recriar aqui DUPLICA (mesmo source_id, só
    # muda o formato do nome). Então em instâncias native_chatwoot NÃO criamos a
    # mensagem — só garantimos o group_jid na conversa (a nativa não seta), p/ o painel
    # de aprovações reconhecer o grupo. Só criamos a msg em provedor NÃO-nativo.
    #
    # EXCEÇÃO [3b]: a perna SECUNDÁRIA do híbrido é SÓ-SAÍDA e NÃO tem ponte nativa de
    # entrega de grupo (a caixa é Cloud oficial, que não faz grupo). Então aqui SIM
    # criamos a mensagem — é a única forma do grupo chegar numa caixa híbrida. O dedup
    # por source_id (abaixo) garante que reentrega não duplica.
    hibrido_secundario = inst.meta.to_h['hybrid_role'] == 'secondary'
    if inst.meta.to_h['native_chatwoot'] && !hibrido_secundario
      ci = existing_group_contact_inbox(inst.inbox, chat)
      conv = ci && inst.inbox.conversations.where(contact_inbox_id: ci.id).order(created_at: :desc).first
      if conv
        ensure_group_jid(conv, chat)
        # aprende o participante mesmo na caixa NATIVA (a msg é criada pela ponte, mas
        # o webhook da sessão ainda chega aqui) — alimenta o roster de participantes.
        Kanban::GroupRoster.learn(conv, jid: d['sender'], name: d['pushName'])
      end
      return
    end

    text = d['text'].presence || d.dig('raw', 'conversation').presence
    return if text.blank?

    # trava ATÔMICA já aqui (antes de criar contato/conversa): sob reentrega do
    # provedor, só a 1ª entrega segue — evita conversa E mensagem duplicadas.
    # Trava pelo ID da mensagem do WhatsApp (ESTÁVEL entre reentregas); só se o id
    # vier vazio caímos na assinatura de conteúdo. IMPORTANTE: NÃO usar timestamp
    # aqui — o AstraCall reentrega com timestamp de RECEBIMENTO diferente, o que
    # fazia a assinatura mudar e ambas as entregas passarem (duplicava).
    msg_id = d['id'].to_s
    claim_key = msg_id.present? ? "gmsg:#{msg_id}" : group_dedup_sig(chat, d, text)
    return unless claim_delivery(inst.inbox_id, claim_key)

    inbox = inst.inbox
    group_name = d['groupName'].presence || d['chatName'].presence ||
                 d['subject'].presence || "Grupo #{chat.split('@').first.to_s[-6..]}"

    # REUSO: a integração NATIVA também pode ter criado o ticket do grupo (contato com
    # identifier = JID do grupo, mas contact_inbox com source_id = UUID). Se existir,
    # reusamos esse contact_inbox p/ NÃO duplicar o ticket. Só criamos um novo se não há.
    contact_inbox = existing_group_contact_inbox(inbox, chat)
    contact_inbox ||= ContactInboxWithContactBuilder.new(
      inbox: inbox, source_id: group_source_id(inbox, chat),
      contact_attributes: { name: group_name, identifier: chat }
    ).perform

    conversation = inbox.conversations
                        .where(contact_inbox_id: contact_inbox.id)
                        .where.not(status: :resolved).order(created_at: :desc).first
    conversation ||= Conversation.create!(
      account_id: inbox.account_id, inbox_id: inbox.id,
      contact_id: contact_inbox.contact_id, contact_inbox_id: contact_inbox.id,
      additional_attributes: { group_jid: chat }
    )
    # garante o group_jid (a nativa não seta) p/ o painel de aprovações reconhecer o grupo
    ensure_group_jid(conversation, chat)

    return if msg_id.present? && conversation.messages.exists?(source_id: msg_id)

    sender = d['pushName'].presence
    content = sender ? "*#{sender}:*\n#{text}" : text
    # participante = JID de QUEM enviou (p/ quando o atendente CITAR essa msg: o AstraCall
    # exige quotedMessageId + quotedParticipant no grupo — ver SecondarySender).
    # citado = WA id da msg que o cliente respondeu (quando o webhook trouxer): grava
    # in_reply_to_external_id e o Chatwoot liga a citação sozinho (ensure_in_reply_to).
    Kanban::GroupRoster.learn(conversation, jid: d['sender'], name: d['pushName'])
    criar_mensagem_grupo(conversation, content, msg_id, d['sender'].presence, extrair_id_citado_grupo(d))
  end

  # Extrai o WA id da mensagem CITADA de um evento de grupo. O AstraCall entrega o
  # contexto DENTRO do raw do Baileys: <tipo>Message.contextInfo.stanzaID (repare o
  # "ID" MAIÚSCULO — Baileys usa stanzaID). Cobrimos também nomes de topo (caso o
  # provedor passe a mandar assim) e o stanzaId minúsculo por segurança.
  def extrair_id_citado_grupo(d)
    return nil unless d.is_a?(Hash)

    topo = d['quotedMessageId'].presence || d['quotedId'].presence ||
           (d['quoted'].is_a?(Hash) ? d['quoted']['id'].presence : d['quoted'].presence) ||
           d.dig('context', 'id').presence ||
           d.dig('contextInfo', 'stanzaID').presence || d.dig('contextInfo', 'stanzaId').presence
    return topo if topo.present?

    ci = contexto_citacao_raw(d['raw'])
    ci && (ci['stanzaID'].presence || ci['stanzaId'].presence)
  end

  # Acha o contextInfo de citação dentro do raw do Baileys. O raw pode ser a própria
  # mensagem ({extendedTextMessage:…}, {imageMessage:…}, …) ou vir sob 'message'. O
  # contextInfo com stanzaID mora dentro do bloco do tipo da mensagem.
  def contexto_citacao_raw(raw)
    return nil unless raw.is_a?(Hash)

    msg = raw['message'].is_a?(Hash) ? raw['message'] : raw
    msg.each_value do |v|
      next unless v.is_a?(Hash)

      ci = v['contextInfo']
      return ci if ci.is_a?(Hash) && (ci['stanzaID'].present? || ci['stanzaId'].present?)
    end
    ci = msg['contextInfo']
    ci.is_a?(Hash) && (ci['stanzaID'].present? || ci['stanzaId'].present?) ? ci : nil
  end

  # Cria a mensagem de ENTRADA do grupo. Na caixa AstraCall pura (Channel::Api) usa o
  # MessageBuilder (caminho consagrado). Na caixa HÍBRIDA (Channel::Whatsapp) o
  # MessageBuilder recusa incoming ("only allowed in Api inboxes"), então construímos
  # a Message direto — igual ao handler de localização. `participant` = JID de quem
  # enviou, guardado em content_attributes.wa_participant p/ a citação de saída.
  def criar_mensagem_grupo(conversation, content, msg_id, participant = nil, quoted_ext_id = nil)
    ca = {}
    ca['wa_participant'] = participant if participant.present?
    ca['in_reply_to_external_id'] = quoted_ext_id if quoted_ext_id.present?
    if conversation.inbox.channel_type == 'Channel::Api'
      return Messages::MessageBuilder.new(nil, conversation, {
                                            content: content, message_type: 'incoming',
                                            source_id: msg_id, content_attributes: ca
                                          }).perform
    end

    msg = conversation.messages.new(
      account_id: conversation.account_id, inbox_id: conversation.inbox_id,
      message_type: :incoming, content_type: 'text',
      content: content, source_id: msg_id.presence, sender: conversation.contact,
      content_attributes: ca
    )
    msg.save!
    msg
  end

  # Nome e foto do contato recém-resolvido na entrada da mensagem.
  def enrich_contact(inst, contact, data)
    # no contato NOVO o builder já gravou o pushName; num contato que já existia
    # quem decide se atualiza é a política única (issue #51)
    Kanban::ContactNamePolicy.apply(contact, data[:name], source: inst.provider)
    # foto de perfil (UazAPI): o webhook já traz a imagem em data[:photo_url]; se não
    # vier (ex.: contato via LID), caímos no job que busca via /chat/GetNameAndImageURL.
    attach_uazapi_photo(inst, contact, data, data[:phone]) if inst.provider == 'uazapi'
  end

  # Anexa a foto de perfil de um contato/grupo (UazAPI). Preferimos a URL que já
  # veio no webhook (data[:photo_url]); sem ela, e sendo 1:1 (number presente),
  # buscamos via /chat/GetNameAndImageURL (resolve LID→número real). Só quando ainda
  # não há avatar, pra não rebaixar uma foto já sincronizada.
  def attach_uazapi_photo(inst, contact, data, number)
    return if contact.nil? || contact.avatar.attached?

    if data[:photo_url].present?
      ::Avatar::AvatarFromUrlJob.perform_later(contact, data[:photo_url])
    elsif number.present?
      Kanban::UazapiContactSyncJob.perform_later(inst.id, contact.id, number)
    end
  end

  # Acha o contact_inbox de um ticket de grupo já existente (criado por nós OU pela
  # integração nativa) pelo contato com identifier = JID do grupo — independentemente
  # do source_id do contact_inbox (a nativa usa UUID; nós usamos o JID). Evita duplicar.
  def existing_group_contact_inbox(inbox, chat)
    contact = inbox.account.contacts.find_by(identifier: chat)
    return nil if contact.nil?

    contact.contact_inboxes.find_by(inbox_id: inbox.id)
  end

  # source_id do contact_inbox de GRUPO. Na caixa AstraCall pura (Channel::Api) o JID
  # (…@g.us) serve direto. Já a caixa HÍBRIDA é Channel::Whatsapp (Cloud), que valida
  # o source_id contra a regex do WhatsApp ( \A(?:\d{1,15}|[A-Z]{2}\.[…]) ): o JID de
  # grupo NÃO passa. Usamos então a forma "GR.<dígitos do jid>", que casa o ramo
  # [A-Z]{2}\.[A-Za-z0-9]{1,128}. O DEDUP não depende disso (é por contact.identifier =
  # JID, que não tem essa regex), então só precisa ser válido e único por grupo.
  def group_source_id(inbox, chat)
    ch = inbox.channel
    return chat unless ch.is_a?(Channel::Whatsapp)

    digits = chat.to_s.gsub(/\D/, '')
    digits.present? ? "GR.#{digits}" : chat
  end

  # Garante additional_attributes.group_jid na conversa (a nativa não seta; o painel
  # de aprovações e a detecção de grupo dependem disso).
  def ensure_group_jid(conversation, chat)
    return if conversation.additional_attributes.is_a?(Hash) && conversation.additional_attributes['group_jid'] == chat

    aa = (conversation.additional_attributes || {}).merge('group_jid' => chat)
    conversation.update!(additional_attributes: aa)
  rescue StandardError => e
    Rails.logger.warn("[Kanban::ProviderWebhook] ensure_group_jid: #{e.message}")
  end

  # Nome do contato no AstraCall (integração nativa): o evento `message` traz o
  # pushName do remetente. Enfileiramos com atraso porque a ponte nativa pode ainda
  # estar criando o contato quando este webhook chega.
  def sync_astracall_contact_name(inst, payload)
    return unless payload['event'] == 'message'

    d = payload['data'] || {}
    return if d['fromMe'] || d['isGroup']

    name = d['pushName'].to_s
    return if name.blank?

    jid = (d['chat'].presence || d['sender']).to_s
    enqueue_contact_name_sync(inst, 'name' => name, 'identifier' => jid, 'phone' => jid_phone(jid))
  end

  # @lid é identificador de privacidade, não telefone — nesse caso o contato só é
  # achado pelo JID (identifier), então não inventamos um número.
  def jid_phone(jid)
    return nil if jid.blank? || jid.end_with?('@lid')

    jid.split('@').first.to_s.gsub(/\D/, '')
  end

  # Idem para Evolution/Evolution Go/WAHA em modo nativo: reusamos os parsers de
  # entrada só para extrair telefone+pushName (a mensagem em si vem pela ponte).
  def sync_native_contact_name(inst, payload)
    data = parse_incoming(inst, payload)
    return if data.nil? || data[:from_me] || data[:is_group]
    return if data[:phone].blank? || data[:name].blank?

    enqueue_contact_name_sync(inst, 'name' => data[:name], 'phone' => data[:phone])
  end

  # atraso: a ponte nativa pode ainda estar criando o contato quando o webhook chega
  def enqueue_contact_name_sync(inst, payload)
    Kanban::ContactNameSyncJob.set(wait: 8.seconds).perform_later(inst.id, payload)
  end

  # extrai { phone, name, text, message_id, from_me } do payload por provedor
  def parse_incoming(inst, payload)
    case inst.provider
    when 'evolution', 'evolution-go' then parse_evolution(payload)
    when 'waha' then parse_waha(payload)
    when 'uazapi' then parse_uazapi(payload)
    end
  end

  def parse_evolution(payload)
    d = payload['data'] || {}
    key = d['key'] || {}
    msg = d['message'] || {}
    text = msg['conversation'] || msg.dig('extendedTextMessage', 'text')
    chat_jid = key['remoteJid'].to_s
    is_group = chat_jid.end_with?('@g.us')
    # Evolution group events use the group's JID as remoteJid. Treating its
    # numeric prefix as a phone number fails Chatwoot's E.164 validation. Keep
    # the group JID as the conversation identity and let the existing group
    # handler create/reuse the group conversation.
    resolved_chat_jid = if chat_jid.end_with?('@lid')
                          key['remoteJidAlt'].presence || d['remoteJidAlt'].presence || chat_jid
                        else
                          chat_jid
                        end
    {
      phone: is_group ? nil : jid_phone(resolved_chat_jid),
      name: d['pushName'], text: text, message_id: key['id'], from_me: key['fromMe'] == true,
      is_group: is_group,
      group_jid: is_group ? chat_jid : nil,
      group_name: is_group ? (d['subject'].presence || d['groupName'].presence || d['chatName'].presence) : nil,
      sender_name: is_group ? d['pushName'] : nil
    }
  end

  def parse_waha(payload)
    p = payload['payload'] || {}
    sender_jid = p['from'].to_s

    # GOWS may expose a privacy LID in from instead of a phone number.
    # WAHA 2026.8+ provides the resolved PN in _data.Info.SenderAlt.
    resolved_sender = sender_jid
    if sender_jid.end_with?('@lid')
      sender_alt = p.dig('_data', 'Info', 'SenderAlt').to_s
      resolved_sender = sender_alt if sender_alt.present? && !sender_alt.end_with?('@lid')
    end

    # Never treat the numeric part of a LID as a telephone number. If WAHA has not
    # resolved it yet, leave phone blank so we don't create a wrong contact.
    phone = if sender_jid.end_with?('@lid') && resolved_sender == sender_jid
              nil
            else
              resolved_sender.split('@').first.to_s.gsub(/\D/, '').presence
            end

    {
      phone: phone,
      name: p.dig('_data', 'notifyName'), text: p['body'], message_id: p['id'], from_me: p['fromMe'] == true
    }
  end

  def parse_uazapi(payload)
    m = payload['message'] || (payload['messages'].is_a?(Array) ? payload['messages'].first : nil) || {}
    # A UazAPI manda junto o objeto `chat` (contato OU grupo) com nome, JID e a FOTO
    # (image/imagePreview) já resolvidos — usamos ele como fonte principal.
    c = payload['chat'].is_a?(Hash) ? payload['chat'] : {}
    chat = (c['wa_chatid'].presence || m['chatid'] || m['chat'] || m['from']).to_s
    is_group = c['wa_isGroup'] == true || m['isGroup'] == true || m['isgroup'] == true || chat.end_with?('@g.us')
    # em grupo, o remetente real é o participante (senderName/sender), não o JID do grupo
    sender_name = m['senderName'] || m['pushname'] || m['senderPushName'] || m['notifyName']
    {
      phone: (m['sender'] || m['from'] || m['chatid']).to_s.split('@').first.to_s.gsub(/\D/, ''),
      name: sender_name, text: m['text'] || m['content'] || m['body'],
      message_id: m['id'] || m['messageid'], from_me: m['fromMe'] == true || m['fromme'] == true,
      is_group: is_group,
      group_jid: is_group ? chat : nil,
      group_name: (is_group ? c['name'].presence : nil) || m['groupName'] || m['chatName'] || m['groupSubject'] || m['subject'],
      photo_url: c['image'].presence || c['imagePreview'].presence,
      sender_name: sender_name
    }
  end

  # 9º dígito (BR): o MESMO assinante chega ora COM 9 (5561996878959) ora SEM
  # (556196878959), conforme o provedor. Procurar só pela forma informada criava um
  # contato/conversa NOVO a cada porta. Aqui resolve por TODAS as variantes antes de
  # criar. Mantém source_id = telefone informado (convenção atual do Channel::Api),
  # então não muda o roteamento de saída das conversas já existentes.
  def dedup_contact_inbox(inbox, data)
    fone = data[:phone].to_s
    variantes = Kanban::PhoneVariants.para(fone)
    conta = inbox.account
    existente =
      if variantes.present?
        conta.contacts.find_by(identifier: variantes.map { |v| "#{v}@s.whatsapp.net" }) ||
          conta.contacts.find_by(phone_number: variantes.map { |v| "+#{v}" })
      end

    if existente
      inbox.contact_inboxes.find_by(contact_id: existente.id) ||
        ContactInbox.create!(contact: existente, inbox: inbox, source_id: fone)
    else
      ContactInboxWithContactBuilder.new(
        inbox: inbox, source_id: fone,
        contact_attributes: { name: data[:name].presence || fone, phone_number: "+#{fone}" }
      ).perform
    end
  end

  def process_incoming(inst, data)
    inbox = inst.inbox
    return if inbox.nil? # instância órfã (inbox deletada)

    # trava atômica antes de criar contato/conversa (reentrega concorrente não duplica)
    return unless claim_delivery(inst.inbox_id, data[:message_id])

    contact_inbox = dedup_contact_inbox(inbox, data)

    enrich_contact(inst, contact_inbox.contact, data)

    # Contato bloqueado ("Bloquear Contato" no cabeçalho → contact.blocked=true):
    # descarta a mensagem de entrada, espelhando o WhatsApp Cloud oficial
    # (incoming_message_base_service: `return if @contact.blocked?`). Os provedores
    # Api (AstraCall/Evolution/WAHA) não herdavam esse comportamento, então bloquear
    # não surtia efeito nessas caixas.
    return if contact_inbox.contact&.blocked?

    conversation = inbox.conversations
                        .where(contact_inbox_id: contact_inbox.id)
                        .where.not(status: :resolved).order(created_at: :desc).first
    conversation ||= Conversation.create!(
      account_id: inbox.account_id, inbox_id: inbox.id,
      contact_id: contact_inbox.contact_id, contact_inbox_id: contact_inbox.id
    )

    return if data[:message_id].present? && conversation.messages.exists?(source_id: data[:message_id])

    # Bolha VAZIA (cliente reclama "mensagem chegando sem nada"): provedores de
    # SESSÃO não-nativos (ex.: uazapi) não extraem mídia na entrada (áudio, figurinha,
    # localização, contato, lista...), então data[:text] vem em branco e, sem guarda,
    # criávamos uma bolha de texto vazia. Em vez de criar a bolha fantasma, mostra um
    # marcador claro de que chegou algo não suportado nesta conexão.
    content = data[:text].to_s.strip
    content = '[mídia/mensagem não suportada nesta conexão]' if content.blank?

    Messages::MessageBuilder.new(nil, conversation, {
                                   content: content, message_type: 'incoming', source_id: data[:message_id]
                                 }).perform
  end

  # #147: bolha de SAÍDA do que o atendente respondeu pelo PRÓPRIO celular (fromMe).
  # Mesma resolução de contato/conversa do incoming, mas message_type 'outgoing'. O
  # source_id (id da msg no provedor) serve pra dedup E pro listener de saída não
  # reenviar (ele pula quem já tem source_id).
  def process_outgoing(inst, data)
    inbox = inst.inbox
    return if inbox.nil?

    return unless claim_delivery(inst.inbox_id, data[:message_id])

    contact_inbox = dedup_contact_inbox(inbox, data)
    enrich_contact(inst, contact_inbox.contact, data)

    conversation = inbox.conversations
                        .where(contact_inbox_id: contact_inbox.id)
                        .where.not(status: :resolved).order(created_at: :desc).first
    conversation ||= Conversation.create!(
      account_id: inbox.account_id, inbox_id: inbox.id,
      contact_id: contact_inbox.contact_id, contact_inbox_id: contact_inbox.id
    )

    return if data[:message_id].present? && conversation.messages.exists?(source_id: data[:message_id])

    content = data[:text].to_s.strip
    content = '[mídia/mensagem não suportada nesta conexão]' if content.blank?

    # A WAHA devolve `fromMe` também para mensagens que acabaram de sair do
    # Chatwoot. O envio já criou uma mensagem com remetente (agente); o eco chega
    # com outro formato de ID e, sem esta reconciliação, virava uma segunda bolha
    # sem remetente (robô). Mensagens enviadas diretamente pelo celular continuam
    # sendo registradas quando não há uma saída equivalente recente do Chatwoot.
    return if reconcile_waha_outgoing_echo(inst, conversation, data, content)

    Messages::MessageBuilder.new(nil, conversation, {
                                   content: content, message_type: 'outgoing', source_id: data[:message_id]
                                 }).perform
  end

  def reconcile_waha_outgoing_echo(inst, conversation, data, content)
    return false unless inst.provider == 'waha' && data[:message_id].present?

    echo_id = data[:message_id].to_s
    return true if conversation.messages.where("content_attributes ->> 'waha_echo_source_id' = ?", echo_id).exists?

    # O ProviderSendJob só grava source_id depois que a WAHA responde. O echo
    # pode chegar nesse intervalo, então exigir source_id aqui deixa passar a
    # segunda bolha. Primeiro priorizamos uma saída ainda sem confirmação do
    # provedor; depois aceitamos uma saída recém-confirmada, cobrindo a corrida
    # em que o job termina antes do webhook.
    recent_messages = conversation.messages
                                  .where(message_type: :outgoing, content: content)
                                  .where.not(sender_id: nil)

    chatwoot_message = recent_messages
                       .where(source_id: [nil, ''])
                       .where(created_at: 15.seconds.ago..Time.current)
                       .order(created_at: :desc)
                       .first

    chatwoot_message ||= recent_messages
                         .where.not(source_id: [nil, ''])
                         .where(created_at: 3.seconds.ago..Time.current)
                         .order(created_at: :desc)
                         .first
    return false unless chatwoot_message

    chatwoot_message.update!(
      content_attributes: chatwoot_message.content_attributes.to_h.merge('waha_echo_source_id' => echo_id)
    )
    Rails.logger.info("[Kanban::ProviderWebhook] WAHA outgoing echo reconciled message_id=#{echo_id}")
    true
  end

  # Mensagem de GRUPO (UazAPI): cria/reusa a conversa do GRUPO (source_id = JID),
  # prefixando o nome de quem falou no conteúdo. Espelha handle_astracall_group_message.
  def process_group_incoming(inst, data)
    inbox = inst.inbox
    return if inbox.nil?

    chat = data[:group_jid].to_s
    return if chat.blank? || data[:text].blank?

    # trava atômica antes de criar contato/conversa (reentrega concorrente não duplica)
    return unless claim_delivery(inst.inbox_id, data[:message_id])

    group_name = data[:group_name].presence || "Grupo #{chat.split('@').first.to_s[-6..]}"
    contact_inbox = existing_group_contact_inbox(inbox, chat)
    contact_inbox ||= ContactInboxWithContactBuilder.new(
      inbox: inbox, source_id: group_source_id(inbox, chat),
      contact_attributes: { name: group_name, identifier: chat }
    ).perform

    # foto do GRUPO: vem no webhook (data[:photo_url]) — anexa ao contato do grupo
    attach_uazapi_photo(inst, contact_inbox.contact, data, nil)

    # grupo "bloqueado" (contact.blocked no contato do grupo) → descarta a entrada
    return if contact_inbox.contact&.blocked?

    conversation = inbox.conversations
                        .where(contact_inbox_id: contact_inbox.id)
                        .where.not(status: :resolved).order(created_at: :desc).first
    conversation ||= Conversation.create!(
      account_id: inbox.account_id, inbox_id: inbox.id,
      contact_id: contact_inbox.contact_id, contact_inbox_id: contact_inbox.id,
      additional_attributes: { group_jid: chat }
    )
    ensure_group_jid(conversation, chat)

    return if data[:message_id].present? && conversation.messages.exists?(source_id: data[:message_id])

    sender = data[:sender_name].presence
    content = sender ? "*#{sender}:*\n#{data[:text]}" : data[:text]
    Messages::MessageBuilder.new(nil, conversation, {
                                   content: content, message_type: 'incoming', source_id: data[:message_id]
                                 }).perform
  end
end
