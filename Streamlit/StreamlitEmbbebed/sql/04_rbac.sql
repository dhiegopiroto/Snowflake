-- =====================================================================
-- 04_rbac.sql
-- Governanca da camada GOLD + identidades da aba "Acesso por Perfil".
--   ANALISTA_JR : NAO ve faturamento (masking) e so ve lojas 2 e 3 (RAP)
--   DIRETOR     : ve tudo
--   SYSADMIN / ACCOUNTADMIN : veem tudo
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------
-- 1) Roles de negocio (abaixo de SYSADMIN, como manda a boa pratica)
-- ---------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS ANALISTA_JR;
CREATE ROLE IF NOT EXISTS DIRETOR;
GRANT ROLE ANALISTA_JR TO ROLE SYSADMIN;
GRANT ROLE DIRETOR     TO ROLE SYSADMIN;

-- Leitura da GOLD + warehouse + uso/embed do app RBAC
GRANT USAGE  ON DATABASE  EMBED_DEMO                    TO ROLE ANALISTA_JR;
GRANT USAGE  ON DATABASE  EMBED_DEMO                    TO ROLE DIRETOR;
GRANT USAGE  ON SCHEMA    EMBED_DEMO.GOLD               TO ROLE ANALISTA_JR;
GRANT USAGE  ON SCHEMA    EMBED_DEMO.GOLD               TO ROLE DIRETOR;
GRANT SELECT ON ALL TABLES IN SCHEMA EMBED_DEMO.GOLD    TO ROLE ANALISTA_JR;
GRANT SELECT ON ALL TABLES IN SCHEMA EMBED_DEMO.GOLD    TO ROLE DIRETOR;
GRANT USAGE  ON WAREHOUSE EMBED_WH                      TO ROLE ANALISTA_JR;
GRANT USAGE  ON WAREHOUSE EMBED_WH                      TO ROLE DIRETOR;
GRANT USAGE  ON SCHEMA    EMBED_DEMO.APPS               TO ROLE ANALISTA_JR;
GRANT USAGE  ON SCHEMA    EMBED_DEMO.APPS               TO ROLE DIRETOR;
GRANT USAGE ON STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS_RBAC TO ROLE ANALISTA_JR;
GRANT USAGE ON STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS_RBAC TO ROLE DIRETOR;
GRANT EMBED ON STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS_RBAC TO ROLE ANALISTA_JR;
GRANT EMBED ON STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS_RBAC TO ROLE DIRETOR;

-- ---------------------------------------------------------------------
-- 2) Masking policy: faturamento so para DIRETOR / SYSADMIN / ACCOUNTADMIN
--    IS_ROLE_IN_SESSION respeita hierarquia (quem herda DIRETOR tambem ve).
-- ---------------------------------------------------------------------
CREATE MASKING POLICY IF NOT EXISTS EMBED_DEMO.GOLD.MP_FATURAMENTO AS (v NUMBER) RETURNS NUMBER ->
  CASE WHEN IS_ROLE_IN_SESSION('DIRETOR')
         OR IS_ROLE_IN_SESSION('SYSADMIN')
         OR IS_ROLE_IN_SESSION('ACCOUNTADMIN') THEN v
       ELSE NULL
  END;

ALTER TABLE EMBED_DEMO.GOLD.FATO_VENDAS MODIFY COLUMN VALOR_ITEM    SET MASKING POLICY EMBED_DEMO.GOLD.MP_FATURAMENTO;
ALTER TABLE EMBED_DEMO.GOLD.FATO_VENDAS MODIFY COLUMN PRECO_VENDIDO SET MASKING POLICY EMBED_DEMO.GOLD.MP_FATURAMENTO;

-- ---------------------------------------------------------------------
-- 3) Row access policy: ANALISTA_JR so ve as lojas 2 e 3
--    Aqui uso CURRENT_ROLE() de proposito: SYSADMIN/ACCOUNTADMIN herdam ANALISTA_JR
--    e, com IS_ROLE_IN_SESSION, seriam filtrados junto.
-- ---------------------------------------------------------------------
CREATE ROW ACCESS POLICY IF NOT EXISTS EMBED_DEMO.GOLD.RAP_LOJAS AS (loja_key NUMBER) RETURNS BOOLEAN ->
  CASE WHEN CURRENT_ROLE() = 'ANALISTA_JR' THEN loja_key IN (2, 3) ELSE TRUE END;

ALTER TABLE EMBED_DEMO.GOLD.FATO_VENDAS ADD ROW ACCESS POLICY EMBED_DEMO.GOLD.RAP_LOJAS ON (LOJA_KEY);
ALTER TABLE EMBED_DEMO.GOLD.DIM_LOJA    ADD ROW ACCESS POLICY EMBED_DEMO.GOLD.RAP_LOJAS ON (LOJA_KEY);

-- ---------------------------------------------------------------------
-- 4) Caller grants: autorizam o OWNER do app (ACCOUNTADMIN) a usar os
--    privilegios de quem esta vendo. Nao dao acesso nenhum por si so.
-- ---------------------------------------------------------------------
GRANT CALLER USAGE ON DATABASE  EMBED_DEMO      TO ROLE ACCOUNTADMIN;
GRANT CALLER USAGE ON SCHEMA    EMBED_DEMO.GOLD TO ROLE ACCOUNTADMIN;
GRANT CALLER USAGE ON WAREHOUSE EMBED_WH        TO ROLE ACCOUNTADMIN;
GRANT INHERITED CALLER SELECT ON ALL TABLES IN SCHEMA EMBED_DEMO.GOLD TO ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------
-- 5) Um usuario de servico POR PERFIL.
--    A sessao caller's rights usa a DEFAULT_ROLE do usuario, nao a role enviada
--    na geracao da URL. Por isso cada perfil tem seu proprio usuario.
-- ---------------------------------------------------------------------
CREATE USER IF NOT EXISTS EMBED_SVC_JR
  TYPE = SERVICE DEFAULT_ROLE = ANALISTA_JR DEFAULT_WAREHOUSE = EMBED_WH
  DEFAULT_SECONDARY_ROLES = () NETWORK_POLICY = EMBED_NP;
CREATE USER IF NOT EXISTS EMBED_SVC_DIR
  TYPE = SERVICE DEFAULT_ROLE = DIRETOR DEFAULT_WAREHOUSE = EMBED_WH
  DEFAULT_SECONDARY_ROLES = () NETWORK_POLICY = EMBED_NP;
GRANT ROLE ANALISTA_JR TO USER EMBED_SVC_JR;
GRANT ROLE DIRETOR     TO USER EMBED_SVC_DIR;

-- PATs (copie cada token_secret para o .env: SNOWFLAKE_PAT_JR / SNOWFLAKE_PAT_DIR)
ALTER USER EMBED_SVC_JR  ADD PROGRAMMATIC ACCESS TOKEN EMBED_PAT_JR  ROLE_RESTRICTION = 'ANALISTA_JR' DAYS_TO_EXPIRY = 30;
ALTER USER EMBED_SVC_DIR ADD PROGRAMMATIC ACCESS TOKEN EMBED_PAT_DIR ROLE_RESTRICTION = 'DIRETOR'     DAYS_TO_EXPIRY = 30;

-- ---------------------------------------------------------------------
-- 6) 1, 2, 3... testando (sessao real, sem roles secundarias)
--    POLICY_CONTEXT nao simula roles secundarias, por isso o teste e com USE ROLE.
-- ---------------------------------------------------------------------
GRANT ROLE ANALISTA_JR TO USER <SEU_USUARIO>;  -- troque pelo seu usuario (SELECT CURRENT_USER())
USE SECONDARY ROLES NONE;
USE ROLE ANALISTA_JR;
SELECT CURRENT_ROLE() AS role, COUNT(DISTINCT LOJA_KEY) AS lojas, COUNT(*) AS itens, SUM(VALOR_ITEM) AS faturamento
FROM EMBED_DEMO.GOLD.FATO_VENDAS;          -- esperado: 2 lojas, faturamento NULL
USE ROLE ACCOUNTADMIN;
USE SECONDARY ROLES ALL;
SELECT CURRENT_ROLE() AS role, COUNT(DISTINCT LOJA_KEY) AS lojas, COUNT(*) AS itens, SUM(VALOR_ITEM) AS faturamento
FROM EMBED_DEMO.GOLD.FATO_VENDAS;          -- esperado: 7 lojas, faturamento preenchido
