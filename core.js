// DNBAR - peças comuns das telas (cozinha, caixa, painel)
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm";

export const SUPABASE_URL = "https://omshldyfjethjufjhkrd.supabase.co";
export const SUPABASE_KEY = "sb_publishable_xLQMg0R5NOM8GA6mShSPiw_TJa7_J1V";
export const sb = createClient(SUPABASE_URL, SUPABASE_KEY);

export const money = c => "R$ " + ((c || 0) / 100).toFixed(2).replace(".", ",").replace(/\B(?=(\d{3})+(?!\d))/g, ".");
export const hhmm = ts => new Date(ts).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });
export const esc = s => String(s ?? "").replace(/[&<>"]/g, m => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[m]));
export const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : "10000000-1000-4000-8000-100000000000".replace(/[018]/g, c => (c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16)));
export const parseMoney = s => { const v = String(s || "").replace(/[^\d,.-]/g, "").replace(/\./g, "").replace(",", "."); const n = Math.round(parseFloat(v) * 100); return isNaN(n) ? null : n; };
export const centsToInput = c => ((c || 0) / 100).toFixed(2).replace(".", ",");

export const ERR = {
  SESSAO_EXPIRADA: "Sua sessão expirou. Entre de novo com o PIN.", SEM_PERMISSAO: "Sua função não permite isso.",
  MESA_OCUPADA: "Essa mesa já está aberta.", MESA_FECHADA: "Essa mesa já foi fechada.", MESA_INVALIDA: "Mesa não encontrada.",
  PEDIDO_VAZIO: "Nada selecionado.", PRODUTO_INVALIDO: "Produto não existe mais.", PRODUTO_ESGOTADO: "Produto esgotado",
  SEM_PRECO: "Produto sem preço", TAMANHO_INVALIDO: "Escolha o tamanho", QUANTIDADE_INVALIDA: "Quantidade inválida.",
  PIN_INVALIDO: "PIN incorreto.", BLOQUEADO: "Muitas tentativas. Aguarde 5 minutos ou chame o gerente.",
  APARELHO_NAO_AUTORIZADO: "Este aparelho não está autorizado.", CAIXA_FECHADO: "O caixa está fechado. Abra o caixa primeiro.",
  CAIXA_JA_ABERTO: "O caixa já está aberto.", VALOR_INVALIDO: "Valor inválido.", MOTIVO_OBRIGATORIO: "Escreva o motivo.",
  PIN_GERENTE_INVALIDO: "PIN do gerente incorreto.", ITEM_INVALIDO: "Esse item não pode mais ser cancelado.",
  FORMA_INVALIDA: "Escolha a forma de pagamento.", RECEBIDO_MENOR: "Valor recebido menor que o valor pago.",
  STATUS_INVALIDO: "Esse pedido já mudou de etapa.", PEDIDO_INVALIDO: "Pedido não encontrado.", PLANO_SEM_DELIVERY: "O plano deste bar não inclui delivery.", PIX_INVALIDO: "Chave Pix inválida para o tipo escolhido."
};
export const isNetErr = e => !navigator.onLine || /fetch|network|Load failed|timeout/i.test(String((e && e.message) || e || ""));
export const errMsg = e => { if (isNetErr(e)) return "Sem conexão. Tente de novo em instantes."; const m = String((e && e.message) || e || ""); const [code, extra] = m.split(":"); return ERR[code] ? (ERR[code] + (extra ? ": " + extra : "")) : "Algo deu errado. Tente de novo."; };

export function initials(name) { return String(name || "?").split(/\s+/).map(w => w[0]).slice(0, 2).join("").toUpperCase(); }
export function avatar(p, size = 44) {
  if (p && p.photo_url) return `<img class="av" src="${esc(p.photo_url)}" alt="" width="${size}" height="${size}" style="width:${size}px;height:${size}px">`;
  return `<span class="av ini" style="width:${size}px;height:${size}px;font-size:${Math.round(size * .38)}px">${esc(initials(p && p.name))}</span>`;
}

// ---- tema (mesmo seletor do app do garçom) ----
export const TEMAS = [["preto", "Preto", "#09090B"], ["branco", "Branco", "#FFFFFF"], ["azul", "Azul", "#0D2A5C"]];
export let TEMA = "preto";
try { const t = localStorage.getItem("dnbar-tema"); if (TEMAS.some(x => x[0] === t)) TEMA = t; } catch (e) { }
export function aplicaTema(t) { if (t) { TEMA = t; try { localStorage.setItem("dnbar-tema", t) } catch (e) { } } document.documentElement.setAttribute("data-tema", TEMA); }
export const temaSwitch = () => `<div class="tema" role="group" aria-label="Cor do fundo">${TEMAS.map(([k, l, c]) => `<button data-a="tema" data-v="${k}" aria-pressed="${TEMA === k}" aria-label="Fundo ${l}"><span style="background:${c}"></span></button>`).join("")}</div>`;
aplicaTema();

export function beep(freq = 880, dur = .35) {
  try { const c = beep.ctx || (beep.ctx = new (window.AudioContext || window.webkitAudioContext)()); const o = c.createOscillator(), g = c.createGain(); o.connect(g); g.connect(c.destination); o.frequency.value = freq; g.gain.setValueAtTime(.25, c.currentTime); g.gain.exponentialRampToValueAtTime(.001, c.currentTime + dur); o.start(); o.stop(c.currentTime + dur); } catch (e) { }
}

// ---- telas de entrada (ativar aparelho, escolher pessoa, PIN) ----
// cfg: {key, roles, title, onLogin}
export function makeGate(cfg) {
  const G = { auth: null, staff: [], bar: null, pinFor: null, pin: "", err: "", busy: false, email: "", pw: "", user: null, token: null, ready: false };
  const keyStore = "dnbar-staff-" + cfg.key;
  G.load = async () => {
    const { data } = await sb.auth.getSession(); G.auth = data.session;
    if (!G.auth) { G.ready = true; return; }
    const [est, st] = await Promise.all([
      sb.from("establishments").select("id,name,logo_url,service_fee_pct,kitchen_enabled,timezone").single(),
      sb.from("staff").select("id,name,role,role_label,photo_url,portrait_url").eq("active", true).order("sort")
    ]);
    if (est.error) throw est.error; if (st.error) throw st.error;
    G.bar = est.data; G.allStaff = st.data; G.staff = st.data.filter(p => cfg.roles.includes(p.role));
    try { const s = JSON.parse(localStorage.getItem(keyStore) || "null"); if (s && G.staff.some(p => p.id === s.id)) { G.user = G.staff.find(p => p.id === s.id); G.token = s.token; } } catch (e) { }
    G.ready = true;
  };
  G.logout = () => { const t = G.token; G.user = null; G.token = null; try { localStorage.removeItem(keyStore) } catch (e) { } if (t) sb.rpc("staff_logout", { p_token: t }); };
  G.view = () => {
    if (!G.auth) return `<div class="gate"><div class="gate-top"><div class="eyebrow">DNBAR · ${esc(cfg.title)}</div>${temaSwitch()}</div>
      <h1 class="big">Ativar este<br>aparelho</h1><p class="muted">Feito uma vez só, pelo gerente ou dono. Depois a equipe entra só com foto e PIN.</p>
      <label class="field">E-mail do bar<input type="email" data-in="email" autocomplete="username" value="${esc(G.email)}"></label>
      <label class="field">Senha<input type="password" data-in="pw" autocomplete="current-password" value="${esc(G.pw)}"></label>
      <div class="err">${esc(G.err)}</div><button class="btn primary block" data-a="g-activate" ${G.busy ? "disabled" : ""}>${G.busy ? "Ativando..." : "Ativar aparelho"}</button></div>`;
    if (G.pinFor) { const p = G.staff.find(x => x.id === G.pinFor);
      return `<div class="gate narrow"><div class="gate-top"><button class="back" data-a="g-back" aria-label="Voltar">‹</button><div class="eyebrow">${esc(G.bar.name)}</div><span></span></div>
        <div class="center">${avatar(p, 108)}<h2>Oi, ${esc(p.name)}</h2><div class="muted">Digite seu PIN de 4 números</div></div>
        <div class="dots">${[0, 1, 2, 3].map(i => `<i class="${i < G.pin.length ? "on" : ""}"></i>`).join("")}</div>
        <div class="pad">${[1, 2, 3, 4, 5, 6, 7, 8, 9].map(n => `<button data-a="g-pin" data-v="${n}">${n}</button>`).join("")}<button class="ghost" data-a="g-back">Trocar</button><button data-a="g-pin" data-v="0">0</button><button class="ghost" data-a="g-del">Apagar</button></div>
        <div class="err">${esc(G.busy ? "Conferindo..." : G.err)}</div></div>`; }
    return `<div class="gate"><div class="gate-top"><div class="eyebrow">${esc(G.bar.name)} · ${esc(cfg.title)}</div>${temaSwitch()}</div>
      ${G.bar.logo_url ? `<img class="logo" src="${esc(G.bar.logo_url)}" alt="${esc(G.bar.name)}">` : ""}
      <h1 class="big">Quem está<br>no ${esc(cfg.title.toLowerCase())}?</h1>
      <div class="people">${G.staff.map(p => `<button class="person" data-a="g-who" data-v="${p.id}">${avatar(p, 72)}<b>${esc(p.name)}</b><span>${esc(p.role_label)}</span></button>`).join("") || `<div class="muted">Nenhuma pessoa cadastrada com essa função.</div>`}</div>
      <div class="switch">Outras telas: <a href="./">Garçom</a> · <a href="cozinha.html">Cozinha/Bar</a> · <a href="caixa.html">Caixa</a> · <a href="delivery.html">Delivery</a> · <a href="painel.html">Dono</a></div></div>`;
  };
  G.pinDigit = async (d, render) => {
    if (G.busy) return; G.pin += d; G.err = "";
    if (G.pin.length < 4) return render();
    G.busy = true; render();
    try {
      const { data, error } = await sb.rpc("staff_login", { p_staff_id: G.pinFor, p_pin: G.pin });
      if (error) throw error;
      if (data.ok) { G.user = G.staff.find(p => p.id === G.pinFor); G.token = data.token; G.pinFor = null; try { localStorage.setItem(keyStore, JSON.stringify({ id: G.user.id, token: G.token })) } catch (e) { } if (cfg.onLogin) cfg.onLogin(); }
      else G.err = ERR[data.error] + (data.error === "PIN_INVALIDO" && data.left != null ? ` Restam ${data.left} tentativas.` : "");
    } catch (e) { G.err = errMsg(e); }
    G.pin = ""; G.busy = false; render();
  };
  // devolve true se tratou o clique
  G.click = async (a, v, render) => {
    switch (a) {
      case "tema": aplicaTema(v); render(); return true;
      case "g-activate": {
        G.busy = true; G.err = ""; render();
        const { data, error } = await sb.auth.signInWithPassword({ email: G.email.trim(), password: G.pw });
        G.busy = false;
        if (error) { G.err = isNetErr(error) ? "Sem conexão com a internet." : "E-mail ou senha incorretos."; render(); return true; }
        G.auth = data.session; G.pw = ""; location.reload(); return true;
      }
      case "g-who": G.pinFor = v; G.pin = ""; G.err = ""; render(); return true;
      case "g-back": G.pinFor = null; G.pin = ""; G.err = ""; render(); return true;
      case "g-del": G.pin = G.pin.slice(0, -1); render(); return true;
      case "g-pin": G.pinDigit(v, render); return true;
    }
    return false;
  };
  G.input = (k, v) => { if (k === "email" || k === "pw") { G[k] = v; return true; } return false; };
  G.key = (e, render) => { if (G.auth && !G.user && G.pinFor && /^\d$/.test(e.key)) { G.pinDigit(e.key, render); return true; } if (e.key === "Enter" && !G.auth) { document.querySelector('[data-a="g-activate"]')?.click(); return true; } return false; };
  return G;
}

export async function rpcT(G, fn, args) {
  const { data, error } = await sb.rpc(fn, Object.assign({ p_token: G.token }, args));
  if (error) { if (/SESSAO_EXPIRADA/.test(error.message)) { G.logout(); } throw error; }
  return data;
}

// CSS comum (tokens iguais ao app do garçom)
export const BASE_CSS = `
html:root[data-tema="preto"]{--bg:#0A0A0B;--surface:#141416;--surface-2:#1E1E21;--line:#2A2A2E;--fg:#F4F4F5;--muted:#9A9AA2;--accent:#F4F4F5;--on-accent:#0A0A0B;--ok:#22C47F;--warn:#F5B000;--bad:#F04452;--bill:#3B82F6;--note-bg:#3A2A00;--note-fg:#FFD45C;--shadow:0 10px 30px rgba(0,0,0,.55);color-scheme:dark}
html:root[data-tema="branco"]{--bg:#F5F6F8;--surface:#FFFFFF;--surface-2:#EEF0F3;--line:#E1E4E9;--fg:#111318;--muted:#5F6672;--accent:#111318;--on-accent:#FFFFFF;--ok:#16A34A;--warn:#D97706;--bad:#DC2626;--bill:#2563EB;--note-bg:#FFF3C4;--note-fg:#7A4B00;--shadow:0 8px 24px rgba(17,19,24,.08);color-scheme:light}
html:root[data-tema="azul"]{--bg:#081428;--surface:#0F1F3B;--surface-2:#172B4D;--line:#22385F;--fg:#EDF3FF;--muted:#90A4C8;--accent:#3B82F6;--on-accent:#FFFFFF;--ok:#22C47F;--warn:#F5B000;--bad:#F04452;--bill:#8B7CF6;--note-bg:#3A2A00;--note-fg:#FFD45C;--shadow:0 10px 30px rgba(0,4,16,.55);color-scheme:dark}
*{box-sizing:border-box}html,body{height:100%;margin:0;overscroll-behavior:none;touch-action:manipulation}
body{background:var(--bg);color:var(--fg);font-family:"Plus Jakarta Sans",system-ui,sans-serif;font-size:16px;-webkit-tap-highlight-color:transparent;position:fixed;inset:0;overflow:hidden;user-select:none;-webkit-user-select:none}
input,textarea{user-select:text;-webkit-user-select:text}
#app{height:100%;display:flex;flex-direction:column;overflow:hidden}
h1,h2,h3{font-family:"Sora",system-ui,sans-serif;margin:0;letter-spacing:-.02em}
button{font:inherit;color:inherit;background:none;border:0;cursor:pointer;padding:0}
button:active{transform:scale(.97)}button:disabled{opacity:.5;cursor:default}
button:focus-visible,input:focus-visible{outline:3px solid var(--bill);outline-offset:2px}
.num{font-variant-numeric:tabular-nums}.muted{color:var(--muted);font-weight:500}
.eyebrow{font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);font-weight:700}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;min-height:50px;padding:0 18px;border-radius:16px;font-weight:700;background:var(--surface-2);border:1px solid var(--line)}
.btn.primary{background:var(--accent);color:var(--on-accent);border:0}.btn.ok{background:var(--ok);color:#04220f;border:0}.btn.bad{background:var(--bad);color:#fff;border:0}
.btn.block{width:100%}.btn.sm{min-height:38px;padding:0 12px;border-radius:12px;font-size:14px}
.tema{display:flex;gap:2px;padding:3px;border-radius:999px;background:var(--surface);border:1px solid var(--line);flex:none}
.tema button{width:26px;height:26px;border-radius:50%;display:grid;place-items:center;border:2px solid transparent}
.tema button span{width:16px;height:16px;border-radius:50%;box-shadow:inset 0 0 0 1px rgba(128,128,128,.55)}
.tema button[aria-pressed="true"]{border-color:var(--fg)}
.av{border-radius:50%;object-fit:cover;flex:none;display:inline-block;background:var(--surface-2)}
.av.ini{display:inline-grid;place-items:center;font-family:"Sora",sans-serif;font-weight:700;background:var(--surface-2);color:var(--fg);border:1px solid var(--line)}
.gate{flex:1;overflow-y:auto;padding:24px 20px;display:flex;flex-direction:column;gap:18px;width:100%;max-width:760px;margin:0 auto}
.gate.narrow{max-width:420px}
.gate-top{display:flex;justify-content:space-between;align-items:center;gap:12px}
.gate .big{font-size:38px;line-height:1.05;font-weight:800}
.gate .center{display:grid;justify-items:center;gap:6px;text-align:center}.gate .center .av{margin-bottom:8px}
.gate .logo{max-height:64px;max-width:220px;object-fit:contain;align-self:flex-start}
.people{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:12px}
.person{display:grid;justify-items:center;gap:6px;padding:18px 10px;border-radius:22px;background:var(--surface);border:1px solid var(--line);text-align:center}
.person b{font-family:"Sora",sans-serif;font-size:18px}.person span{font-size:12px;color:var(--muted);font-weight:700;text-transform:uppercase;letter-spacing:.08em}
.dots{display:flex;gap:16px;justify-content:center}.dots i{width:16px;height:16px;border-radius:50%;background:var(--surface-2);border:2px solid var(--line)}.dots i.on{background:var(--accent);border-color:transparent}
.pad{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}
.pad button{height:62px;border-radius:18px;background:var(--surface);border:1px solid var(--line);font-family:"Sora",sans-serif;font-size:24px;font-weight:600}
.pad button.ghost{background:none;border:0;font-family:inherit;font-size:15px;color:var(--muted)}
.back{width:44px;height:44px;border-radius:14px;background:var(--surface);border:1px solid var(--line);font-size:26px;line-height:1}
.err{color:var(--bad);font-weight:700;text-align:center;min-height:20px}
.field{display:grid;gap:6px;font-weight:600;font-size:14px;color:var(--muted)}
.field input,.field select,.field textarea{height:50px;border-radius:14px;border:1px solid var(--line);background:var(--surface);color:var(--fg);padding:0 14px;font:inherit;font-size:17px;font-weight:600;width:100%}
.field textarea{height:80px;padding:10px 14px;resize:none}
.switch{font-size:13px;color:var(--muted);text-align:center;margin-top:auto}.switch a{color:var(--fg);font-weight:700}
.toast{position:fixed;left:50%;transform:translateX(-50%);top:14px;z-index:90;background:var(--surface);border:1px solid var(--line);box-shadow:var(--shadow);border-radius:18px;padding:12px 16px;font-weight:700;max-width:calc(100% - 24px)}
.toast small{display:block;color:var(--muted);font-weight:600}
.toast.bad{border-color:var(--bad)}
.modal-bg{position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:80;display:grid;place-items:center;padding:16px}
.modal{background:var(--bg);border:1px solid var(--line);border-radius:24px;padding:20px;width:100%;max-width:440px;max-height:90vh;overflow-y:auto;display:flex;flex-direction:column;gap:14px;box-shadow:var(--shadow)}
.modal-h{display:flex;justify-content:space-between;align-items:center;gap:10px}
.chips{display:flex;gap:8px;flex-wrap:wrap}
.chip{min-height:40px;padding:0 14px;border-radius:999px;background:var(--surface);border:1px solid var(--line);font-weight:700;font-size:14px}
.chip[aria-pressed="true"]{background:var(--accent);color:var(--on-accent);border-color:transparent}
.net{position:fixed;left:50%;transform:translateX(-50%);bottom:14px;z-index:70;background:var(--warn);color:#1a1200;font-weight:800;font-size:13px;padding:8px 14px;border-radius:999px}
`;
