import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import {
  getAuth, onAuthStateChanged, signInWithEmailAndPassword, signOut,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import {
  getFirestore, collection, doc, getDoc, addDoc, updateDoc, onSnapshot, serverTimestamp,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";
import { firebaseConfig } from "./firebase-config.js";

const app = initializeApp(firebaseConfig);
const auth = getAuth(app);
const db = getFirestore(app);

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

let estandes = [];          // [{id, nome, descricao, localizacao, ativo}]
let checkins = [];          // [{id, estandeId, visitanteId, criadoEm}]
let totaisAnteriores = {};
let unsubs = [];
const destacados = new Set(JSON.parse(localStorageGet("missao_sel") || "[]"));

function localStorageGet(k) { try { return localStorage.getItem(k); } catch { return null; } }
function localStorageSet(k, v) { try { localStorage.setItem(k, v); } catch { /* ignore */ } }

// ---------------------------------------------------------------- Auth
onAuthStateChanged(auth, async (user) => {
  unsubs.forEach((u) => u()); unsubs = [];
  if (!user || user.isAnonymous) {
    mostrar("login");
    return;
  }
  try {
    const adm = await getDoc(doc(db, "admins", user.uid));
    if (!adm.exists()) {
      $("loginErro").textContent =
        `Este usuário não é administrador. Crie no Firestore o documento admins/${user.uid}.`;
      await signOut(auth);
      return;
    }
  } catch (e) {
    $("loginErro").textContent = "Erro ao verificar administrador: " + e.message;
    await signOut(auth);
    return;
  }
  $("emailAdmin").textContent = user.email;
  mostrar("painel");
  ouvirDados();
});

function mostrar(tela) {
  $("telaLogin").classList.toggle("hidden", tela !== "login");
  $("telaPainel").classList.toggle("hidden", tela !== "painel");
  $("usuario").classList.toggle("hidden", tela !== "painel");
}

$("formLogin").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  $("loginErro").textContent = "";
  try {
    await signInWithEmailAndPassword(auth, $("loginEmail").value.trim(), $("loginSenha").value);
  } catch (e) {
    $("loginErro").textContent = traduzErro(e);
  }
});
$("btnSair").addEventListener("click", () => signOut(auth));

function traduzErro(e) {
  const c = e.code || "";
  if (c.includes("invalid-credential") || c.includes("wrong-password") || c.includes("user-not-found"))
    return "E-mail ou senha incorretos.";
  if (c.includes("unauthorized-domain"))
    return "Domínio não autorizado: adicione este site em Authentication → Configurações → Domínios autorizados.";
  if (c.includes("permission-denied")) return "Permissão negada pelas regras do Firestore.";
  return e.message || String(e);
}

// ---------------------------------------------------------------- Dados em tempo real
function ouvirDados() {
  unsubs.push(onSnapshot(collection(db, "estandes"), (snap) => {
    estandes = snap.docs.map((d) => ({ id: d.id, ...d.data() }))
      .sort((a, b) => (a.nome || "").localeCompare(b.nome || "", "pt-BR"));
    render();
  }, (e) => erroTabela(e)));

  unsubs.push(onSnapshot(collection(db, "checkins"), (snap) => {
    checkins = snap.docs.map((d) => ({ id: d.id, ...d.data() }));
    render();
  }, (e) => erroTabela(e)));
}

function erroTabela(e) {
  $("tabela").innerHTML = `<tr><td colspan="7" class="erro">${esc(traduzErro(e))}</td></tr>`;
}

function render() {
  // Totais por estande calculados a partir dos registros do Firestore
  const totais = {};
  for (const c of checkins) totais[c.estandeId] = (totais[c.estandeId] || 0) + 1;

  $("mEstandes").textContent = estandes.length;
  $("mAtivos").textContent = estandes.filter((e) => e.ativo).length;
  $("mCheckins").textContent = checkins.length;
  $("mVisitantes").textContent = new Set(checkins.map((c) => c.visitanteId)).size;

  const tb = $("tabela");
  if (!estandes.length) {
    tb.innerHTML = `<tr><td colspan="7" class="vazio">Nenhum estande cadastrado.</td></tr>`;
  } else {
    tb.innerHTML = estandes.map((e) => {
      const t = totais[e.id] || 0;
      const mudou = totaisAnteriores[e.id] !== undefined && totaisAnteriores[e.id] !== t;
      return `<tr class="${mudou ? "flash" : ""}">
        <td><input type="checkbox" class="estrela" data-sel="${e.id}" ${destacados.has(e.id) ? "checked" : ""}></td>
        <td><b>${esc(e.nome)}</b><div class="desc">${esc(e.descricao)}</div></td>
        <td>${esc(e.localizacao)}</td>
        <td><span class="selo ${e.ativo ? "on" : "off"}">${e.ativo ? "Ativo" : "Inativo"}</span></td>
        <td class="num">${t}</td>
        <td class="mono">${e.id}<br><button class="mini sec" data-copiar="${e.id}">copiar</button></td>
        <td><div class="acoes">
          <button class="mini" data-qr="${e.id}">QR code</button>
          <button class="mini sec" data-editar="${e.id}">Editar</button>
          <button class="mini sec" data-toggle="${e.id}">${e.ativo ? "Desativar" : "Ativar"}</button>
        </div></td>
      </tr>`;
    }).join("");
  }
  totaisAnteriores = totais;

  // Últimos check-ins
  const nomes = Object.fromEntries(estandes.map((e) => [e.id, e.nome]));
  const ult = [...checkins]
    .sort((a, b) => (b.criadoEm?.toMillis?.() || 0) - (a.criadoEm?.toMillis?.() || 0))
    .slice(0, 8);
  $("ultimos").innerHTML = ult.length ? ult.map((c) => `<li>
      <span>${esc(nomes[c.estandeId] || c.estandeNome || c.estandeId)}</span>
      <small>visitante ${esc(String(c.visitanteId).slice(0, 6))}… · ${c.criadoEm?.toDate ? c.criadoEm.toDate().toLocaleTimeString("pt-BR") : "agora"}</small>
    </li>`).join("") : `<li class="vazio">Nenhum check-in ainda.</li>`;

  atualizarMissao();
}

// ---------------------------------------------------------------- Ações da tabela
$("tabela").addEventListener("click", async (ev) => {
  const b = ev.target.closest("button");
  if (!b) return;
  const est = (id) => estandes.find((e) => e.id === id);
  if (b.dataset.qr) abrirQr(est(b.dataset.qr));
  if (b.dataset.editar) editar(est(b.dataset.editar));
  if (b.dataset.copiar) copiar(b.dataset.copiar, b);
  if (b.dataset.toggle) {
    const e = est(b.dataset.toggle);
    try {
      await updateDoc(doc(db, "estandes", e.id), {
        nome: e.nome, descricao: e.descricao || "", localizacao: e.localizacao || "",
        ativo: !e.ativo, atualizadoEm: serverTimestamp(),
      });
    } catch (err) { alertaForm(traduzErro(err), true); }
  }
});

$("tabela").addEventListener("change", (ev) => {
  const id = ev.target.dataset?.sel;
  if (!id) return;
  ev.target.checked ? destacados.add(id) : destacados.delete(id);
  localStorageSet("missao_sel", JSON.stringify([...destacados]));
  atualizarMissao();
});

function atualizarMissao() {
  const validos = [...destacados].filter((id) => estandes.some((e) => e.id === id));
  $("valorMissao").textContent = validos.length ? validos.join(",") : "(nenhum selecionado)";
}
$("btnCopiarMissao").addEventListener("click", (ev) => {
  const v = $("valorMissao").textContent;
  if (!v.startsWith("(")) copiar(v, ev.target);
});

async function copiar(texto, botao) {
  try {
    await navigator.clipboard.writeText(texto);
    const o = botao.textContent; botao.textContent = "copiado!";
    setTimeout(() => (botao.textContent = o), 1200);
  } catch { prompt("Copie:", texto); }
}

// ---------------------------------------------------------------- Formulário
function editar(e) {
  $("estId").value = e.id;
  $("estNome").value = e.nome || "";
  $("estDesc").value = e.descricao || "";
  $("estLocal").value = e.localizacao || "";
  $("estAtivo").checked = !!e.ativo;
  $("tituloForm").textContent = "Editar estande";
  $("btnCancelar").classList.remove("hidden");
  $("estNome").focus();
}
function limparForm() {
  $("formEstande").reset();
  $("estId").value = "";
  $("estAtivo").checked = true;
  $("tituloForm").textContent = "Cadastrar estande";
  $("btnCancelar").classList.add("hidden");
}
$("btnCancelar").addEventListener("click", limparForm);

function alertaForm(t, erro = false) {
  const m = $("formMsg");
  m.textContent = t; m.className = erro ? "erro" : "msg";
  if (!erro) setTimeout(() => (m.textContent = ""), 3000);
}

$("formEstande").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const dados = {
    nome: $("estNome").value.trim(),
    descricao: $("estDesc").value.trim(),
    localizacao: $("estLocal").value.trim(),
    ativo: $("estAtivo").checked,
    atualizadoEm: serverTimestamp(),
  };
  if (!dados.nome) return alertaForm("Informe o nome.", true);
  try {
    const id = $("estId").value;
    if (id) {
      await updateDoc(doc(db, "estandes", id), dados);
      alertaForm("Estande atualizado.");
    } else {
      await addDoc(collection(db, "estandes"), { ...dados, criadoEm: serverTimestamp() });
      alertaForm("Estande cadastrado.");
    }
    limparForm();
  } catch (e) { alertaForm(traduzErro(e), true); }
});

$("btnExemplos").addEventListener("click", async () => {
  const exemplos = [
    { nome: "EcoRota Amazônia", descricao: "App que sugere rotas de barco com menor consumo de combustível entre comunidades ribeirinhas.", localizacao: "Corredor A · Estande 03" },
    { nome: "Açaí Tracker", descricao: "Rastreabilidade do açaí do produtor ao consumidor com QR code e blockchain.", localizacao: "Corredor C · Estande 14" },
    { nome: "SaúdeRibeirinha", descricao: "Telemedicina offline-first para agentes de saúde em áreas sem internet.", localizacao: "Corredor D · Estande 21" },
  ];
  try {
    for (const e of exemplos) {
      await addDoc(collection(db, "estandes"), { ...e, ativo: true, criadoEm: serverTimestamp(), atualizadoEm: serverTimestamp() });
    }
    alertaForm("3 estandes de exemplo criados.");
  } catch (e) { alertaForm(traduzErro(e), true); }
});

// ---------------------------------------------------------------- QR code
let qrObj = null;
function abrirQr(e) {
  const texto = "circuito:" + e.id;
  $("qrNome").textContent = e.nome;
  $("qrLocal").textContent = e.localizacao || "";
  $("qrTexto").textContent = texto;
  $("qrBox").innerHTML = "";
  qrObj = new QRCode($("qrBox"), { text: texto, width: 280, height: 280, correctLevel: QRCode.CorrectLevel.M });
  const p = new URLSearchParams({ id: e.id, nome: e.nome, local: e.localizacao || "" });
  $("btnAbrirQr").href = "qr.html?" + p.toString();
  $("modalQr").classList.remove("hidden");
}
$("btnFecharQr").addEventListener("click", () => $("modalQr").classList.add("hidden"));
$("modalQr").addEventListener("click", (ev) => { if (ev.target.id === "modalQr") $("modalQr").classList.add("hidden"); });
$("btnImprimir").addEventListener("click", () => window.print());
