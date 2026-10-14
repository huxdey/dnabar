# DNBAR

SaaS operacional para bares. Hoje no ar: **app do garçom** ligado ao banco de verdade (Supabase), em tempo real.

## Como funciona
- `index.html`: app do garçom (HTML + CSS + JS num arquivo só, sem etapa de build).
- `supabase/migrations/`: estrutura do banco, regras de segurança e dados iniciais.
- `sw.js` + `manifest.webmanifest`: deixam o app instalável (PWA) e abrindo mesmo com internet oscilando.
- Publicação: Vercel lê este repositório e publica a cada mudança na `main`.

## Segurança (resumo)
- Cada bar só enxerga os próprios dados (Row Level Security).
- Aparelho precisa ser ativado com e-mail e senha do bar; depois a equipe entra com foto + PIN.
- PIN guardado só como hash; 5 erros bloqueiam por 5 minutos.
- Nada é gravado direto nas tabelas: tudo passa por funções no banco que conferem o PIN, a mesa e o preço.
- Preço sempre calculado no servidor. Pedido tem chave única: nunca duplica, nem com internet caindo.

Detalhes do andamento em `PROGRESSO.md`.
