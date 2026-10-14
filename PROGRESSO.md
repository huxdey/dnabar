# Progresso do DNBAR

> Arquivo de continuidade: numa conversa nova, peça para o Claude ler este arquivo antes de tudo.

## Infra
- Supabase: projeto `dnbar` (id `omshldyfjethjufjhkrd`, região São Paulo).
- Repositório: `huxdey/dnabar` (branch `main` = produção). Tag `v1-base` = protótipo original.
- Hospedagem: Vercel, projeto `dnabar` (conta huxdeybetuel-8055). Link fixo: https://dnabar.vercel.app (publica sozinho a cada push na main).

## Etapa 1 - concluída (14/10/2026)
- Banco: bares, equipe, PIN, mesas, cardápio, sessões de mesa, pedidos, itens, linha do tempo/auditoria.
- Funções: `staff_login`, `staff_logout`, `open_table`, `create_order` (idempotente, preço no servidor), `deliver_ready`, `ack_call`, `send_to_cashier`, `transfer_table`.
- App do garçom ligado ao banco: ativar aparelho, foto + PIN real, abrir mesa, lançar pedido, repetir rodada, transferir, entregar, mandar conta ao caixa.
- Tempo real (Supabase Realtime) + atualização a cada 30 s como reserva.
- Fila offline de pedidos com aviso na tela.
- PWA instalável.
- Dados de teste: cardápio do Cumbuca's, 6 pessoas na equipe com PIN 1234, 30 mesas.
- Cozinha está DESLIGADA no bar (`kitchen_enabled = false`): o garçom marca "Entreguei" direto.

## Etapa 2 - concluída (14/10/2026): cozinha, caixa e dono
- `cozinha.html`: tela da cozinha/bar (tablet deitado). Cartão por pedido com mesa, garçom, cronômetro (âmbar 12 min, vermelho 20 min), observação em destaque, cancelado em vermelho, som de pedido novo, PRONTO por pedido ou por item, desfazer. Filtro Cozinha / Bar / Tudo.
- `caixa.html`: mesas ao vivo (quem pediu conta primeiro), conta com serviço liga/desliga, desconto e cancelamento com PIN de gerente + motivo, pagamento por forma (Pix, débito, crédito, dinheiro com troco), dividir por N, pagamento parcial, mesa fecha sozinha ao zerar. Venda balcão. Abertura, sangria, suprimento e fechamento com conferência.
- `painel.html`: login próprio do dono (sessão separada do aparelho). Faturamento com comparação, ticket médio, gasto por pessoa, mais/menos vendidos, não vendidos, formas de pagamento, horário de movimento, equipe, cancelamentos, descontos, caixas. Aba Cardápio: preço e esgotado.
- App do garçom: conta mostra desconto e já pago; garçom registra pagamento na maquininha (fecha a mesa). Lista de login só garçom e gerente.
- Banco (migração 005): `cash_sessions`, `cash_movements`, `payments`, `counter_sales`, `counter_sale_items`; funções `set_items_ready`, `undo_ready`, `cash_open/move/close/status`, `set_service_fee`, `set_discount`, `cancel_item`, `pay`, `counter_sale`, `owner_report`, `owner_update_product`, `whoami`. Cada função confere a função (role) de quem chama.
- Equipe de teste nova: Rosa (cozinha), Tiago (bar), Júlia (caixa). PIN 1234. Gerente Marcela autoriza descontos e cancelamentos.
- Conta do dono do Cumbuca's: `dono.cumbucas@dnbar.app`.
- `core.js`: peças comuns das telas novas (conexão, login com PIN, tema, CSS base).
- Cozinha LIGADA no Cumbuca's (`kitchen_enabled = true`).

## Pendências conhecidas
- Trocar os PINs de teste (1234) antes de uso real.
- Cadastro público bloqueado no banco (migração 003). Reforço opcional: desligar "Allow new users to sign up" no painel do Supabase.
- Pedido pelo QR do cliente: fora do escopo por enquanto.

## Próximas etapas
3. Configuração completa no painel do dono: fotos (Supabase Storage), novos produtos e categorias, logo e cor, equipe (foto, PIN, desativar), mesas, aparelhos.
4. Painel da plataforma (do Hux): criar bares, gerar acessos, ver quem paga.

Especificação completa: docs `SAAS_BAR_RESTAURANTE.md` + `SAAS_BAR_RESTAURANTE_ADENDO_1.md` no projeto do Claude.
