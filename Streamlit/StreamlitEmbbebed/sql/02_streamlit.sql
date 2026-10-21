-- =====================================================================
-- 02_streamlit.sql
-- Publica os dois apps Streamlit em CONTAINER RUNTIME (requisito do embedding).
--   RELATORIO_VENDAS       -> owner's rights (todo mundo ve o mesmo)
--   RELATORIO_VENDAS_RBAC  -> restricted caller's rights (cada um ve o que pode)
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- Compute pool onde os apps rodam (o menor tipo de CPU basta)
CREATE COMPUTE POOL IF NOT EXISTS EMBED_POOL
  MIN_NODES = 1 MAX_NODES = 1
  INSTANCE_FAMILY = CPU_X64_XS
  AUTO_SUSPEND_SECS = 600;

-- Stage com o codigo dos apps
CREATE STAGE IF NOT EXISTS EMBED_DEMO.APPS.CODIGO
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Codigo-fonte dos apps Streamlit da demo de embedding';

-- ---------------------------------------------------------------------
-- ANTES DE SEGUIR: envie os arquivos da pasta streamlit/ para o stage.
--
-- Opcao A (Snowsight): Data > Databases > EMBED_DEMO > APPS > Stages > CODIGO
--   > "+ Files" e crie as pastas relatorio/ e relatorio_rbac/ com:
--   streamlit_app.py, pyproject.toml, .streamlit/config.toml
--
-- Opcao B (Snowflake CLI), a partir da raiz do repositorio:
--   snow stage copy streamlit/relatorio      @EMBED_DEMO.APPS.CODIGO/relatorio      --recursive
--   snow stage copy streamlit/relatorio_rbac @EMBED_DEMO.APPS.CODIGO/relatorio_rbac --recursive
-- ---------------------------------------------------------------------
LIST @EMBED_DEMO.APPS.CODIGO;   -- confira se os 6 arquivos estao la

-- App 1: owner's rights
CREATE OR REPLACE STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS
  FROM '@EMBED_DEMO.APPS.CODIGO/relatorio/'
  MAIN_FILE       = 'streamlit_app.py'
  QUERY_WAREHOUSE = EMBED_WH
  COMPUTE_POOL    = EMBED_POOL
  RUNTIME_NAME    = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
  TITLE           = 'Relatorio de Vendas';

-- App 2: restricted caller's rights (mesmo relatorio, outra conexao)
CREATE OR REPLACE STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS_RBAC
  FROM '@EMBED_DEMO.APPS.CODIGO/relatorio_rbac/'
  MAIN_FILE       = 'streamlit_app.py'
  QUERY_WAREHOUSE = EMBED_WH
  COMPUTE_POOL    = EMBED_POOL
  RUNTIME_NAME    = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
  TITLE           = 'Relatorio de Vendas RBAC';

-- Confira: runtime_name deve ser SYSTEM$ST_CONTAINER_RUNTIME_PY3_11
DESCRIBE STREAMLIT EMBED_DEMO.APPS.RELATORIO_VENDAS;
-- Abra os dois apps no Snowsight (Projects > Streamlit) uma vez para validar que sobem.
-- O RBAC vai dar erro de permissao como ACCOUNTADMIN ate rodar o 04_rbac.sql: e esperado.
