"""Portal de Vendas - demo de Streamlit in Snowflake embedded.

Rotas:
  /login   login fixo da demo (admin / 123)
  /        aba Relatorio: app owner's rights, todo mundo ve o mesmo
  /perfis  aba Acesso por Perfil: app caller's rights, cada perfil ve o que pode
"""
import os

import requests
from dotenv import load_dotenv
from flask import Flask, redirect, render_template_string, request, session, url_for

load_dotenv()

app = Flask(__name__)
app.secret_key = os.urandom(24)

USUARIO, SENHA = "admin", "123"  # apenas para demo, nunca em producao

# Perfis da aba "Acesso por Perfil". Quem decide a role e o BACKEND, nunca o navegador.
# Cada perfil tem seu proprio usuario de servico + PAT (a sessao caller's rights usa a
# DEFAULT_ROLE do usuario).
PERFIS = {
    "ana.jr": {"nome": "Ana (Analista JR)", "role": "ANALISTA_JR", "pat_env": "SNOWFLAKE_PAT_JR",
               "acesso": "Lojas 2 e 3 · sem faturamento"},
    "carlos.diretor": {"nome": "Carlos (Diretor)", "role": "DIRETOR", "pat_env": "SNOWFLAKE_PAT_DIR",
                       "acesso": "Todas as lojas · com faturamento"},
}


def gerar_embed_url(app_fqn: str, pat: str, role: str) -> str:
    """Pede ao Snowflake uma embed URL de uso unico (vale 10 minutos)."""
    db, schema, name = app_fqn.split(".")
    # hostname nao aceita "_" (o certificado SSL e emitido com "-")
    account_url = os.environ["SNOWFLAKE_ACCOUNT_URL"].replace("_", "-")
    resp = requests.post(
        f"{account_url}/api/v2/databases/{db}/schemas/{schema}/streamlits/{name}:generate-embed-url",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {pat}",
            "X-Snowflake-Authorization-Token-Type": "PROGRAMMATIC_ACCESS_TOKEN",
            "X-Snowflake-Role": role,  # obrigatorio: nao ha fallback para a default role
        },
        # precisa ser EXATAMENTE a origem de onde o navegador abre o portal
        json={"parent_origin": os.environ["PARENT_ORIGIN"]},
        timeout=30,
    )
    if not resp.ok:
        raise RuntimeError(f"{resp.status_code}: {resp.text}")
    return resp.json()["embed_url"]


HEAD = """<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Portal de Vendas</title>
<link rel="icon" href="{{ url_for('static', filename='snowflake.svg') }}">
<link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}"></head>"""

LOGIN_HTML = HEAD + """
<body><main class="login">
  <section class="hero">
    <div class="brand"><img src="{{ url_for('static', filename='snowflake.svg') }}" alt="Snowflake">Snowflake</div>
    <div>
      <h1>Portal de <span>Vendas</span></h1>
      <p>Relatórios Streamlit rodando dentro do Snowflake, embutidos de forma segura na sua aplicação.</p>
    </div>
    <div class="foot">powered by Streamlit in Snowflake</div>
  </section>
  <section class="panel">
    <form class="card" method="post">
      <h2>Bem-vindo</h2>
      <p class="sub">Entre para acessar o relatório</p>
      <div class="field"><input id="user" name="user" placeholder=" " autofocus required><label for="user">Usuário</label></div>
      <div class="field"><input id="password" name="password" type="password" placeholder=" " required><label for="password">Senha</label></div>
      <button class="btn">Entrar <span>&rarr;</span></button>
      {% if erro %}<div class="alert">{{ erro }}</div>{% endif %}
    </form>
  </section>
</main></body></html>
"""

# Uma pagina so para as duas abas; a de perfis mostra o seletor acima do iframe
PAGE_HTML = HEAD + """
<body>
<header class="topbar">
  <div class="brand"><img src="{{ url_for('static', filename='snowflake.svg') }}" alt="Snowflake">
    <span class="title">Portal de Vendas</span><span class="chip">EMBEDDED · SNOWFLAKE</span></div>
  <nav class="tabs">
    <a href="/" class="{{ 'active' if aba == 'relatorio' }}">Relatório</a>
    <a href="/perfis" class="{{ 'active' if aba == 'perfis' }}">Acesso por Perfil</a>
  </nav>
  <div class="user"><div class="avatar">A</div><span class="name">admin</span>
    <a class="logout" href="/logout">Sair</a></div>
</header>
<main class="stage {{ 'perfis' if perfil }}">
  {% if perfil %}
  <form class="profilebar" method="get">
    <label for="usuario">Usuário fazendo o request</label>
    <select id="usuario" name="usuario" onchange="this.form.submit()">
      {% for k, p in perfis.items() %}<option value="{{ k }}" {{ 'selected' if k == usuario }}>{{ p.nome }}</option>{% endfor %}
    </select>
    <span class="rolechip {{ perfil.role|lower }}">ROLE · {{ perfil.role }}</span>
    <span class="access">{{ perfil.acesso }}</span>
  </form>
  {% endif %}
  <div class="frame">
  {% if erro %}
    <div class="error-card"><div class="icon">!</div><h3>Não foi possível carregar o relatório</h3>
      <p>Confira o .env e os grants no Snowflake.</p><code>{{ erro }}</code></div>
  {% else %}
    <div class="loading" id="loading">
      <div class="msg"><img src="{{ url_for('static', filename='snowflake.svg') }}" alt="">Iniciando app no Snowflake...</div>
      <div class="sk-row"><div class="sk sk-kpi"></div><div class="sk sk-kpi"></div><div class="sk sk-kpi"></div><div class="sk sk-kpi"></div></div>
      <div class="sk sk-chart"></div>
    </div>
    <iframe id="app" src="{{ embed_url }}" title="Relatório de Vendas" allow="clipboard-read; clipboard-write; fullscreen"></iframe>
    <script>
      const hide = () => document.getElementById("loading").classList.add("done");
      // o app embedado avisa por postMessage quando terminou de renderizar
      window.addEventListener("message", (e) => {
        if (e.origin.endsWith(".snowflake.app") && e.data?.type === "SNOWFLAKE_EMBED_LOADED") hide();
      });
      document.getElementById("app").addEventListener("load", () => setTimeout(hide, 4000));
    </script>
  {% endif %}
  </div>
</main>
</body></html>
"""


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if request.form["user"] == USUARIO and request.form["password"] == SENHA:
            session["logado"] = True
            return redirect(url_for("index"))
        return render_template_string(LOGIN_HTML, erro="Usuário ou senha inválidos")
    return render_template_string(LOGIN_HTML)


@app.route("/")
def index():
    if not session.get("logado"):
        return redirect(url_for("login"))
    ctx = dict(aba="relatorio", perfil=None)
    try:
        url = gerar_embed_url(os.environ["STREAMLIT_APP"], os.environ["SNOWFLAKE_PAT"], os.environ["SNOWFLAKE_ROLE"])
        return render_template_string(PAGE_HTML, embed_url=url, **ctx)
    except Exception as e:
        return render_template_string(PAGE_HTML, erro=str(e), **ctx)


@app.route("/perfis")
def perfis():
    if not session.get("logado"):
        return redirect(url_for("login"))
    usuario = request.args.get("usuario", "ana.jr")
    if usuario not in PERFIS:
        usuario = "ana.jr"
    perfil = PERFIS[usuario]
    ctx = dict(aba="perfis", perfis=PERFIS, usuario=usuario, perfil=perfil)
    try:
        url = gerar_embed_url(os.environ["STREAMLIT_APP_RBAC"], os.environ[perfil["pat_env"]], perfil["role"])
        return render_template_string(PAGE_HTML, embed_url=url, **ctx)
    except Exception as e:
        return render_template_string(PAGE_HTML, erro=str(e), **ctx)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


if __name__ == "__main__":
    # 8080 e nao 5000: no macOS a 5000 e do AirPlay Receiver
    app.run(host="localhost", port=8080)
