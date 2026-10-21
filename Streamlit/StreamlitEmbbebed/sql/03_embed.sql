-- =====================================================================
-- 03_embed.sql
-- Libera o embedding e cria o usuario de servico que GERA as embed URLs
-- do app owner's rights (RELATORIO_VENDAS).
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- 1) Quais origens podem colocar os apps num iframe.
--    localhost em http e permitido so para teste local. Em producao: https://seu.portal.com
ALTER ACCOUNT SET STREAMLIT_EMBEDDING_CONTROLS = $$
allowed_embedding_domains:
  - http://localhost:8080
$$;
SHOW PARAMETERS LIKE 'STREAMLIT_EMBEDDING_CONTROLS' IN ACCOUNT;

-- 2) Role minima: so enxerga e embeda UM app
CREATE ROLE IF NOT EXISTS EMBED_MINTER;
GRANT USAGE ON DATABASE EMBED_DEMO                     TO ROLE EMBED_MINTER;
GRANT USAGE ON SCHEMA   EMBED_DEMO.APPS                TO ROLE EMBED_MINTER;
GRANT USAGE ON STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS TO ROLE EMBED_MINTER;
GRANT EMBED ON STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS TO ROLE EMBED_MINTER;  -- ser owner NAO implica EMBED

-- 3) Network policy: o PAT de um usuario SERVICE exige uma.
--    Troque pelo IP publico da maquina que roda o portal (curl ifconfig.me).
CREATE NETWORK POLICY IF NOT EXISTS EMBED_NP ALLOWED_IP_LIST = ('<SEU_IP_PUBLICO>');

-- 4) Usuario de servico (sem senha, sem login interativo)
CREATE USER IF NOT EXISTS EMBED_SVC
  TYPE = SERVICE
  DEFAULT_ROLE = EMBED_MINTER
  NETWORK_POLICY = EMBED_NP
  COMMENT = 'Gera embed URLs do RELATORIO_VENDAS';
GRANT ROLE EMBED_MINTER TO USER EMBED_SVC;

-- 5) PAT preso a role EMBED_MINTER. O token_secret aparece UMA vez: copie para o .env (SNOWFLAKE_PAT)
ALTER USER EMBED_SVC ADD PROGRAMMATIC ACCESS TOKEN EMBED_PAT
  ROLE_RESTRICTION = 'EMBED_MINTER'
  DAYS_TO_EXPIRY = 30
  COMMENT = 'Demo Streamlit embedded';
