# Progresso do DNBAR

> Arquivo de continuidade: numa conversa nova, peça para o Claude ler este arquivo antes de tudo.

## Infra
- Supabase: projeto `dnbar` (id `omshldyfjethjufjhkrd`, região São Paulo).
- Repositório: `huxdey/dnabar` (branch `main` = produção). Tag `v1-base` = protótipo original.
- Hospedagem: Vercel importando este repositório (sem build, site estático).

## Etapa 1 - concluída (14/10/2026)
- Banco: bares, equipe, PIN, mesas, cardápio, sessões de mesa, pedidos, itens, linha do tempo/auditoria.
- Funções: `staff_login`, `staff_logout`, `open_table`, `create_order` (idempotente, preço no servidor), `deliver_ready`, `ack_call`, `send_to_cashier`, `transfer_table`.
- App do garçom ligado ao banco: ativar aparelho, foto + PIN real, abrir mesa, lançar pedido, repetir rodada, transferir, entregar, mandar conta ao caixa.
- Tempo real (Supabase Realtime) + atualização a cada 30 s como reserva.
- Fila offline de pedidos com aviso na tela.
- PWA instalável.
- Dados de teste: cardápio do Cumbuca's, 6 pessoas na equipe com PIN 1234, 30 mesas.
- Cozinha está DESLIGADA no bar (`kitchen_enabled = false`): o garçom marca "Entreguei" direto.

## Pendências conhecidas
- Trocar os PINs de teste (1234) antes de uso real.
- Cadastro público bloqueado no banco (migração 003). Reforço opcional: desligar "Allow new users to sign up" no painel do Supabase.
- Pedido pelo QR do cliente: fora do escopo por enquanto.

## Próximas etapas
2. Tela da cozinha/bar (KDS): `cozinha.html`, ligar `kitchen_enabled`, função `set_items_ready`, som, cronômetro, observação grande, cancelado em destaque.
3. Caixa: `caixa.html`, pagamento (forma, parcial, dividida), taxa de serviço, venda balcão, desconto/cancelamento com PIN de gerente, abertura/sangria/fechamento de caixa.
4. Dono/configuração: relatórios dia/semana/mês, cardápio, equipe (foto, PIN, desativar), mesas, aparelhos.

Especificação completa: docs `SAAS_BAR_RESTAURANTE.md` + `SAAS_BAR_RESTAURANTE_ADENDO_1.md` no projeto do Claude.
