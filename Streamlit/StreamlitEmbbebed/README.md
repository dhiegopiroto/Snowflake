# Streamlit in Snowflake embedded

Material do artigo **"Streamlit in Snowflake embedded: seu relatório dentro de qualquer aplicação (e cada usuário vendo só o que pode)"**.

Um portal Flask local que exibe, via iframe, dois apps Streamlit rodando no Snowflake:

- **Relatório:** app em owner's rights. Todo mundo vê os mesmos dados.
- **Acesso por Perfil:** app em restricted caller's rights. A Ana (Analista JR) vê só as lojas 2 e 3 e não vê faturamento. O Carlos (Diretor) vê tudo.

## Estrutura

```
artigo_medium.md              texto do artigo (pronto pro Medium)
sql/
  01_dados.sql                warehouse, database e dados sinteticos (GOLD)
  02_streamlit.sql            compute pool, stage e os 2 apps em container runtime
  03_embed.sql                dominio permitido, EMBED_MINTER, EMBED_SVC e PAT
  04_rbac.sql                 roles, masking, row access, caller grants, 1 usuario por perfil
  99_cleanup.sql              remove tudo
streamlit/
  relatorio/                  app owner's rights
  relatorio_rbac/             app caller's rights
portal/
  app.py                      backend Flask (gera as embed URLs)
  static/                     CSS e logo
  .env.example                variaveis de ambiente
diagramas/                    arquitetura e fluxo em Mermaid
```

## Passo a passo resumido

1. Rode `sql/01_dados.sql` como ACCOUNTADMIN.
2. Rode a primeira parte de `sql/02_streamlit.sql` (compute pool e stage). Suba a pasta `streamlit/` para o stage `@EMBED_DEMO.APPS.CODIGO` e rode o resto do script.
3. Em `sql/03_embed.sql`, troque `<SEU_IP_PUBLICO>` e rode o script. Guarde o `token_secret`.
4. Em `sql/04_rbac.sql`, troque `<SEU_USUARIO>` e rode o script. Guarde os dois `token_secret`.
5. Rode o portal:
   ```bash
   cd portal
   python -m venv .venv && source .venv/bin/activate
   pip install -r requirements.txt
   cp .env.example .env      # preencha URL da conta e os 3 PATs
   python app.py
   ```
6. Abra **http://localhost:8080** (use `localhost`, não `127.0.0.1`) e entre com `admin` / `123`.
7. Quando terminar, rode `sql/99_cleanup.sql`.

## Requisitos

- Conta Snowflake (trial serve) em uma região com Snowpark Container Services; Streamlit em container runtime depende disso.
- Role ACCOUNTADMIN.
- Python 3.10+.

> Demo apenas. Login fixo, PATs no `.env` e um IP liberado não são configurações de produção.
