# Streamlit in Snowflake embedded: seu relatório dentro de qualquer aplicação (e cada usuário vendo só o que pode)

Fala, pessoal.

Quem trabalha com dados já viveu essa cena: o relatório ficou pronto, bonito, rodando dentro do Snowflake... e aí alguém pergunta: "dá pra colocar isso dentro do nosso portal?". O portal do cliente, a intranet, o sistema interno do time comercial. Lugares onde o usuário final nunca vai abrir o Snowsight.

A saída clássica é reescrever o dashboard em outra ferramenta, criar uma API, duplicar regra de negócio e torcer para os números baterem. Hoje dá pra fazer diferente: o Streamlit in Snowflake pode ser **embutido via iframe** em qualquer página externa, de forma segura, com URL temporária e respeitando as políticas de governança que você já tem no Snowflake.

Neste artigo vou mostrar o passo a passo completo, reproduzível em uma conta trial: a teoria, os componentes, um portal de exemplo e, no final, o mesmo relatório mostrando **dados diferentes para usuários diferentes**, com masking e row access policy. Todo o código está no repositório do artigo.

---

## Por que embedar um Streamlit?

Antes do como, o porquê. A proposta de valor é bem direta:

• **O dado não sai do Snowflake.** O app roda dentro da sua conta e a sua aplicação só exibe o resultado. Nada de exportar CSV ou montar API intermediária.

• **Um relatório, vários lugares.** O mesmo app aparece no Snowsight, no portal do cliente e na intranet. Mudou o código, mudou em todo lugar.

• **Governança herdada.** Grants, masking policies e row access policies continuam valendo. Você não reimplementa segurança na camada de apresentação.

• **Sem credencial no navegador.** O browser nunca recebe usuário, senha ou token do Snowflake, só uma URL descartável.

mas..Dhiego...como isso funciona por baixo?

---

## Como funciona (a teoria)

De forma MUITO SIMPLISTA, existem três atores:

1. **Snowflake:** hospeda o app Streamlit e decide quem pode exibi-lo e de onde.
2. **Seu backend:** autentica no Snowflake e pede uma *embed URL* para o app.
3. **O navegador:** recebe a página com um `<iframe>` apontando para essa URL.

A peça central é a **embed URL**:

• é gerada no servidor, por uma chamada REST (`generate-embed-url`);
• é de **uso único** e vale **10 minutos**;
• carrega exatamente o acesso da role com que foi gerada;
• só funciona se a página que hospeda o iframe estiver numa **origem registrada** na conta.

O fluxo de uma visita fica assim:

**Navegador** → login no portal
→ **Portal** chama a API do Snowflake com um token (PAT) e uma role
→ **Snowflake** devolve a embed URL
→ **Portal** responde com o HTML contendo o iframe
→ **Navegador** carrega o app direto do Snowflake (`*.snowflake.app`)

[screenshot: diagrama de arquitetura - diagramas/arquitetura.mmd]

## Owner's rights x caller's rights

Esse é o conceito que separa um embed "bonito" de um embed "governado".

**Owner's rights (padrão)**
• As queries rodam com a role **dona** do app.
• Todo mundo que abre o app vê os mesmos dados.
• Perfeito para dashboards públicos ou de visão única.

**Restricted caller's rights**
• As queries rodam com as permissões de **quem está vendo**.
• Masking e row access policies passam a valer por usuário.
• O admin libera explicitamente quais privilégios o app pode usar (os *caller grants*).
• Só existe em **container runtime**, que também é requisito para o embedding.

Neste tutorial vamos fazer os dois.

---

## Componentes da solução

**No Snowflake**
• `EMBED_DEMO.GOLD`: camada gold com dados sintéticos (fato de vendas + lojas + produtos)
• `EMBED_POOL`: compute pool onde os apps rodam
• `RELATORIO_VENDAS`: app owner's rights
• `RELATORIO_VENDAS_RBAC`: o mesmo app em caller's rights
• `STREAMLIT_EMBEDDING_CONTROLS`: parâmetro de conta com as origens permitidas
• `EMBED_SVC`, `EMBED_SVC_JR`, `EMBED_SVC_DIR`: usuários de serviço que geram as URLs
• `MP_FATURAMENTO` e `RAP_LOJAS`: masking e row access policy

**Na sua máquina**
• Um portal Flask com login, duas abas e o iframe

**Os perfis da demo**
• Ana (Analista JR): só lojas 2 e 3, sem faturamento
• Carlos (Diretor): tudo

---

## Pré-requisitos

• Conta Snowflake (trial serve) numa região com Snowpark Container Services, porque o Streamlit em container runtime roda sobre ele
• Role ACCOUNTADMIN
• Python 3.10+
• O código do artigo: [link do repositório]

Bom, chega de blablabla e vamos trabalhar.

---

## HANDS ON! Passo 1: os dados

Como é uma conta trial, vamos gerar uma camada gold sintética: 7 lojas, 40 produtos e 500 mil itens vendidos no último ano. O script completo é o `sql/01_dados.sql`; o coração dele é este:

```sql
-- Fato de vendas: 500 mil itens nos ultimos 365 dias
CREATE OR REPLACE TABLE FATO_VENDAS AS
WITH base AS (
  SELECT SEQ8() + 1                 AS ITEM_ID,
         DATEADD(minute, -UNIFORM(0, 525600, RANDOM()), CURRENT_TIMESTAMP())::TIMESTAMP_NTZ AS DATA_HORA_VENDA,
         UNIFORM(1, 7, RANDOM())    AS LOJA_KEY,      -- 7 lojas
         UNIFORM(1, 40, RANDOM())   AS PRODUTO_KEY,   -- 40 produtos
         UNIFORM(1, 5, RANDOM())    AS QUANTIDADE
  FROM TABLE(GENERATOR(ROWCOUNT => 500000))
),
precos AS (
  -- preco praticado = preco de tabela com 0 a 15% de desconto
  SELECT b.*, (p.PRECO_TABELA * UNIFORM(85, 100, RANDOM()) / 100)::NUMBER(18,2) AS PRECO_VENDIDO
  FROM base b JOIN DIM_PRODUTO p ON p.PRODUTO_KEY = b.PRODUTO_KEY
)
SELECT ITEM_ID, CEIL(ITEM_ID / 3) AS VENDA_ID, DATA_HORA_VENDA, LOJA_KEY, PRODUTO_KEY,
       QUANTIDADE, PRECO_VENDIDO,
       (QUANTIDADE * PRECO_VENDIDO)::NUMBER(18,2) AS VALOR_ITEM   -- o faturamento
FROM precos;
```

No final do script tem um `SELECT` por loja; você deve ver 7 linhas com algo perto de 71 mil itens cada.

---

## Passo 2: publicar os apps em container runtime

Primeiro, a infraestrutura: um compute pool e um stage para o código.

```sql
-- Compute pool onde os apps rodam (o menor tipo basta)
CREATE COMPUTE POOL IF NOT EXISTS EMBED_POOL
  MIN_NODES = 1 MAX_NODES = 1
  INSTANCE_FAMILY = CPU_X64_XS
  AUTO_SUSPEND_SECS = 600;

CREATE STAGE IF NOT EXISTS EMBED_DEMO.APPS.CODIGO DIRECTORY = (ENABLE = TRUE);
```

Agora suba a pasta `streamlit/` do repositório para o stage. Pode ser pelo Snowsight (Data → Databases → EMBED_DEMO → APPS → Stages → CODIGO → "+ Files") ou pela Snowflake CLI:

```bash
snow stage copy streamlit/relatorio      @EMBED_DEMO.APPS.CODIGO/relatorio      --recursive
snow stage copy streamlit/relatorio_rbac @EMBED_DEMO.APPS.CODIGO/relatorio_rbac --recursive
```

Feito isso, criamos os dois apps. Repare no `RUNTIME_NAME`: é ele que coloca o app em **container runtime**.

```sql
CREATE OR REPLACE STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS
  FROM '@EMBED_DEMO.APPS.CODIGO/relatorio/'
  MAIN_FILE       = 'streamlit_app.py'
  QUERY_WAREHOUSE = EMBED_WH
  COMPUTE_POOL    = EMBED_POOL
  RUNTIME_NAME    = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'   -- container runtime
  TITLE           = 'Relatorio de Vendas';
```

O `RELATORIO_VENDAS_RBAC` é idêntico, só apontando para a pasta `relatorio_rbac/`. A diferença entre os dois está no código Python. No owner's rights:

```python
# Conexao padrao = direitos do owner do app
conn = st.connection("snowflake")
```

No caller's rights:

```python
# Conexao com os direitos de quem esta vendo
conn = st.connection("snowflake-callers-rights")
```

Pronto! Abra o `RELATORIO_VENDAS` no Snowsight (Projects → Streamlit) para validar que ele sobe.

[screenshot: relatório aberto no Snowsight]

---

## Passo 3: liberar o embedding

Por padrão, nenhuma página externa pode colocar seus apps num iframe. Quem libera é o parâmetro de conta `STREAMLIT_EMBEDDING_CONTROLS`:

```sql
-- Origens que podem hospedar o iframe.
-- http so e aceito para localhost; em producao use https://seu.portal.com
ALTER ACCOUNT SET STREAMLIT_EMBEDDING_CONTROLS = $$
allowed_embedding_domains:
  - http://localhost:8080
$$;
```

Por que 8080 e não a clássica 5000 do Flask? No macOS a porta 5000 é do **AirPlay Receiver**. Eu perdi um tempinho nessa. rs

---

## Passo 4: o usuário que gera as URLs

O backend precisa de uma identidade no Snowflake. A recomendação é um usuário `TYPE = SERVICE` com uma role mínima, que só enxerga e embeda **um** app:

```sql
CREATE ROLE IF NOT EXISTS EMBED_MINTER;
GRANT USAGE ON DATABASE EMBED_DEMO          TO ROLE EMBED_MINTER;
GRANT USAGE ON SCHEMA   EMBED_DEMO.APPS     TO ROLE EMBED_MINTER;
GRANT USAGE ON STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS TO ROLE EMBED_MINTER;
GRANT EMBED ON STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS TO ROLE EMBED_MINTER;  -- ser owner NAO implica EMBED

-- PAT de usuario SERVICE exige network policy (troque pelo seu IP: curl ifconfig.me)
CREATE NETWORK POLICY IF NOT EXISTS EMBED_NP ALLOWED_IP_LIST = ('<SEU_IP_PUBLICO>');

CREATE USER IF NOT EXISTS EMBED_SVC
  TYPE = SERVICE DEFAULT_ROLE = EMBED_MINTER NETWORK_POLICY = EMBED_NP;
GRANT ROLE EMBED_MINTER TO USER EMBED_SVC;

-- O token_secret aparece UMA vez: copie para o .env
ALTER USER EMBED_SVC ADD PROGRAMMATIC ACCESS TOKEN EMBED_PAT
  ROLE_RESTRICTION = 'EMBED_MINTER' DAYS_TO_EXPIRY = 30;
```

Um detalhe que pega muita gente: **ser dono do app não dá o privilégio EMBED**. Ele precisa ser concedido explicitamente, até para o owner.

---

## Passo 5: o portal

O portal é um Flask de um arquivo só (`portal/app.py`). A parte que importa é a função que gera a embed URL:

```python
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
            "X-Snowflake-Role": role,   # obrigatorio: nao ha fallback para a default role
        },
        # precisa ser EXATAMENTE a origem de onde o navegador abre o portal
        json={"parent_origin": os.environ["PARENT_ORIGIN"]},
        timeout=30,
    )
    if not resp.ok:
        raise RuntimeError(f"{resp.status_code}: {resp.text}")
    return resp.json()["embed_url"]
```

E no HTML, basta isso:

```html
<iframe src="{{ embed_url }}" allow="clipboard-read; clipboard-write; fullscreen"></iframe>
```

Um bônus: o app embedado avisa a página pai por `postMessage` quando termina de renderizar (`SNOWFLAKE_EMBED_LOADED`). Eu uso isso para esconder um skeleton de loading enquanto o container sobe.

Para rodar:

```bash
cd portal
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env    # preencha a URL da conta e o PAT
python app.py
```

## 1, 2, 3... testando

Abra **http://localhost:8080** e entre com `admin` / `123`.

[screenshot: tela de login do portal]

[screenshot: aba Relatório com o Streamlit embedado]

Viram como é simples? O relatório que estava no Snowsight agora está dentro de uma aplicação nossa, e o navegador nunca viu credencial nenhuma do Snowflake.

Mas...espere! Até aqui todo mundo vê o mesmo relatório. E se o analista júnior não puder ver faturamento?

---

## HANDS ON 2: cada usuário, seus dados

Agora vem a parte que eu acho mais legal. O objetivo:

• **ANALISTA_JR:** não vê faturamento e só vê as lojas 2 e 3
• **DIRETOR:** vê tudo
• **SYSADMIN / ACCOUNTADMIN:** veem tudo

Tudo isso está no `sql/04_rbac.sql`.

## Passo 6: roles e políticas

Primeiro a **masking policy** do faturamento:

```sql
CREATE MASKING POLICY IF NOT EXISTS EMBED_DEMO.GOLD.MP_FATURAMENTO AS (v NUMBER) RETURNS NUMBER ->
  CASE WHEN IS_ROLE_IN_SESSION('DIRETOR')
         OR IS_ROLE_IN_SESSION('SYSADMIN')
         OR IS_ROLE_IN_SESSION('ACCOUNTADMIN') THEN v
       ELSE NULL                      -- qualquer outra role ve NULL
  END;

ALTER TABLE EMBED_DEMO.GOLD.FATO_VENDAS MODIFY COLUMN VALOR_ITEM    SET MASKING POLICY EMBED_DEMO.GOLD.MP_FATURAMENTO;
ALTER TABLE EMBED_DEMO.GOLD.FATO_VENDAS MODIFY COLUMN PRECO_VENDIDO SET MASKING POLICY EMBED_DEMO.GOLD.MP_FATURAMENTO;
```

Depois a **row access policy** das lojas:

```sql
CREATE ROW ACCESS POLICY IF NOT EXISTS EMBED_DEMO.GOLD.RAP_LOJAS AS (loja_key NUMBER) RETURNS BOOLEAN ->
  CASE WHEN CURRENT_ROLE() = 'ANALISTA_JR' THEN loja_key IN (2, 3) ELSE TRUE END;

ALTER TABLE EMBED_DEMO.GOLD.FATO_VENDAS ADD ROW ACCESS POLICY EMBED_DEMO.GOLD.RAP_LOJAS ON (LOJA_KEY);
ALTER TABLE EMBED_DEMO.GOLD.DIM_LOJA    ADD ROW ACCESS POLICY EMBED_DEMO.GOLD.RAP_LOJAS ON (LOJA_KEY);
```

Você pode estar se perguntando: "por que `IS_ROLE_IN_SESSION` numa e `CURRENT_ROLE()` na outra?"

Porque as duas roles de negócio ficam **abaixo de SYSADMIN** na hierarquia. Ou seja, SYSADMIN e ACCOUNTADMIN *herdam* ANALISTA_JR. Se a RAP usasse `IS_ROLE_IN_SESSION('ANALISTA_JR')`, o admin também ficaria preso nas lojas 2 e 3. Já na masking a herança é o que queremos: quem herda DIRETOR também vê faturamento.

## Passo 7: caller grants

Num app caller's rights, o Snowflake só usa os privilégios do viewer que o admin liberou explicitamente para o **owner** do app. Esses são os *caller grants*:

```sql
GRANT CALLER USAGE ON DATABASE  EMBED_DEMO      TO ROLE ACCOUNTADMIN;
GRANT CALLER USAGE ON SCHEMA    EMBED_DEMO.GOLD TO ROLE ACCOUNTADMIN;
GRANT CALLER USAGE ON WAREHOUSE EMBED_WH        TO ROLE ACCOUNTADMIN;
GRANT INHERITED CALLER SELECT ON ALL TABLES IN SCHEMA EMBED_DEMO.GOLD TO ROLE ACCOUNTADMIN;
```

Eles não dão acesso nenhum por si só. Funcionam como um filtro: "o app pode usar o SELECT de quem está vendo, se essa pessoa tiver SELECT".

## Passo 8: um usuário de serviço por perfil (a pegadinha!)

Minha primeira ideia foi usar um único usuário de serviço com as duas roles e mandar a role certa no header `X-Snowflake-Role`. A URL era gerada sem erro... e o app abria com a role **EMBED_MINTER**.

O motivo está na documentação, em uma linha só: a sessão caller's rights usa a **DEFAULT_ROLE do usuário**, e não a role com que a URL foi gerada.

A alternativa? Um usuário de serviço por perfil, cada um com a role certa como padrão:

```sql
CREATE USER IF NOT EXISTS EMBED_SVC_JR
  TYPE = SERVICE DEFAULT_ROLE = ANALISTA_JR DEFAULT_WAREHOUSE = EMBED_WH
  DEFAULT_SECONDARY_ROLES = () NETWORK_POLICY = EMBED_NP;
CREATE USER IF NOT EXISTS EMBED_SVC_DIR
  TYPE = SERVICE DEFAULT_ROLE = DIRETOR DEFAULT_WAREHOUSE = EMBED_WH
  DEFAULT_SECONDARY_ROLES = () NETWORK_POLICY = EMBED_NP;
GRANT ROLE ANALISTA_JR TO USER EMBED_SVC_JR;
GRANT ROLE DIRETOR     TO USER EMBED_SVC_DIR;

-- Um PAT para cada (copie os dois token_secret para o .env)
ALTER USER EMBED_SVC_JR  ADD PROGRAMMATIC ACCESS TOKEN EMBED_PAT_JR  ROLE_RESTRICTION = 'ANALISTA_JR';
ALTER USER EMBED_SVC_DIR ADD PROGRAMMATIC ACCESS TOKEN EMBED_PAT_DIR ROLE_RESTRICTION = 'DIRETOR';
```

De quebra, cada usuário tem uma única role, então não tem como DIRETOR "vazar" como role secundária na sessão da Ana.

## Passo 9: os ajustes no app caller's rights

Três linhas no topo do `relatorio_rbac/streamlit_app.py` fazem toda a diferença:

```python
conn = st.connection("snowflake-callers-rights")
# so a role principal conta nas policies
conn.cursor().execute("USE SECONDARY ROLES NONE")
# a sessao caller's rights NAO herda o DEFAULT_WAREHOUSE do usuario
conn.cursor().execute("USE WAREHOUSE EMBED_WH")
```

E uma no cache, que é fácil de esquecer e perigosa:

```python
# sem scope="session", o cache e compartilhado entre viewers:
# a Ana poderia receber o resultado em cache do Carlos
@st.cache_data(ttl=600, scope="session")
def q(sql: str):
    return conn.query(sql, ttl=0)
```

## Passo 10: o seletor de perfil no portal

No portal, a aba "Acesso por Perfil" tem um dropdown. Quem escolhe a role é o **backend**, a partir do perfil; nunca o navegador:

```python
PERFIS = {
    "ana.jr":         {"role": "ANALISTA_JR", "pat_env": "SNOWFLAKE_PAT_JR"},
    "carlos.diretor": {"role": "DIRETOR",     "pat_env": "SNOWFLAKE_PAT_DIR"},
}
# ...
perfil = PERFIS[usuario]
url = gerar_embed_url(os.environ["STREAMLIT_APP_RBAC"], os.environ[perfil["pat_env"]], perfil["role"])
```

## 1, 2, 3... testando de novo

Reinicie o portal e abra `http://localhost:8080/perfis`.

[screenshot: perfil Ana - 2 lojas, faturamento R$ 0,00 e aviso de masking]

[screenshot: perfil Carlos - 7 lojas e faturamento completo]

Mesmo app, mesma URL de origem, mesmo código. Resultados diferentes, decididos pelas políticas que estão **na camada de dados**. Bem bacana, né?

Se quiser validar fora do app, use uma sessão real; o `POLICY_CONTEXT` não simula roles secundárias:

```sql
USE SECONDARY ROLES NONE;
USE ROLE ANALISTA_JR;
SELECT COUNT(DISTINCT LOJA_KEY) AS lojas, SUM(VALOR_ITEM) AS faturamento
FROM EMBED_DEMO.GOLD.FATO_VENDAS;   -- esperado: 2 lojas, faturamento NULL
```

---

## Pegadinhas que eu pisei (troubleshooting)

**Hostname mismatch / SSL**
• URL da conta com `_` (ex.: `minhaorg-minha_conta`). O certificado é emitido com `-`. Troque `_` por `-`.

**403 / código 390403**
• O `parent_origin` enviado não está em `allowed_embedding_domains`. Precisa ser idêntico, porta incluída.

**400 Bad Request**
• PAT inválido, ainda com o placeholder, ou sem o header `X-Snowflake-Role`.

**iframe em branco**
• Você abriu `127.0.0.1:8080`, mas registrou `localhost:8080`. Para o navegador são origens diferentes.

**"Database does not exist or not authorized ... must have CALLER USAGE"**
• Faltam caller grants. `CALLER DATA READ` sozinho não bastou para mim; precisei dos grants detalhados (database, schema, warehouse e SELECT nas tabelas).

**"No active warehouse selected"**
• A sessão caller's rights não herdou o `DEFAULT_WAREHOUSE` do usuário. Resolva com `USE WAREHOUSE` no app.

**App abre com a role errada**
• A sessão caller's rights usa a DEFAULT_ROLE do usuário. Um usuário de serviço por perfil.

**Atualizei o código e o app não mudou**
• Confira a versão publicada com `DESCRIBE STREAMLIT` e, se preciso, recrie o app a partir do stage.

---

## E em produção?

Calma, jovem padawan: login fixo e PAT no `.env` são para demo. Não preciso dizer pra não fazer isso em prod, né?

O caminho para produção é o modelo "viewers com conta Snowflake": cada pessoa entra pelo seu IdP (Entra ID, Okta...), via integração **External OAuth**, e o backend gera a embed URL com o **token OAuth do próprio usuário** (`X-Snowflake-Authorization-Token-Type: OAUTH`). Com isso:

• some o usuário de serviço por perfil: a role vem dos grupos do IdP, provisionados por SCIM;
• a auditoria (`QUERY_HISTORY`) passa a mostrar a pessoa real, e não um service user;
• masking, RAP e o app caller's rights continuam **exatamente iguais**.

Um detalhe importante: o SSO SAML do Snowsight não basta. O backend precisa de um token OAuth que a API do Snowflake aceite; por isso a integração é External OAuth.

---

## Limpeza

Terminou de brincar? O `sql/99_cleanup.sql` remove usuários, network policy, database, compute pool, warehouse, roles e volta o parâmetro de embedding ao padrão. O compute pool é o que mais custa crédito parado, então não esqueça dele.

---

E é assim que podemos levar um relatório Streamlit para dentro de qualquer aplicação, sem tirar o dado do Snowflake e sem reimplementar segurança na camada de apresentação. :)

Por hoje é isso.

**Referências**
• [Embedding Streamlit in Snowflake apps in external pages](https://docs.snowflake.com/en/developer-guide/streamlit/features/embedding/overview)
• [Embed for viewers without a Snowflake account](https://docs.snowflake.com/en/developer-guide/streamlit/features/embedding/external-users)
• [Embed for viewers with a Snowflake account](https://docs.snowflake.com/en/developer-guide/streamlit/features/embedding/snowflake-users)
• [Restricted caller's rights and Streamlit in Snowflake](https://docs.snowflake.com/en/developer-guide/streamlit/features/restricted-callers-rights)
• [Restricted caller's rights](https://docs.snowflake.com/en/developer-guide/restricted-callers-rights)
• [Security overview for Streamlit in Snowflake](https://docs.snowflake.com/en/developer-guide/streamlit/object-management/security)

[]'s

Piroto

---

*O conteúdo deste post representa ideias, opiniões e fatos trazidos para fins informativos; são meus e não representam pensamentos ou opiniões das empresas citadas. Não há profundidade técnica para ser considerado um artigo e sua principal função é somente de informar e trazer campo para discussões informais; Sempre valide a documentação oficial, antes de alterar qualquer configuração.*
