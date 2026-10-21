-- =====================================================================
-- 01_dados.sql
-- Cria database, warehouse e uma camada GOLD com dados SINTETICOS de vendas.
-- Rodar como ACCOUNTADMIN em uma worksheet do Snowsight.
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- Warehouse pequeno pra demo (suspende sozinho em 60s)
CREATE WAREHOUSE IF NOT EXISTS EMBED_WH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS EMBED_DEMO;
CREATE SCHEMA IF NOT EXISTS EMBED_DEMO.GOLD;
CREATE SCHEMA IF NOT EXISTS EMBED_DEMO.APPS;   -- onde ficam os apps Streamlit
USE SCHEMA EMBED_DEMO.GOLD;
USE WAREHOUSE EMBED_WH;

-- Dimensao de lojas: 7 lojas fixas
CREATE OR REPLACE TABLE DIM_LOJA (
    LOJA_KEY  NUMBER  COMMENT 'Chave da loja (1 a 7)',
    NOME_LOJA STRING  COMMENT 'Nome da loja',
    UF        STRING  COMMENT 'Estado da loja'
) AS
SELECT column1, column2, column3 FROM VALUES
  (1, 'Loja 1 - Paulista',   'SP'),
  (2, 'Loja 2 - Savassi',    'MG'),
  (3, 'Loja 3 - Copacabana', 'RJ'),
  (4, 'Loja 4 - Batel',      'PR'),
  (5, 'Loja 5 - Moinhos',    'RS'),
  (6, 'Loja 6 - Boa Viagem', 'PE'),
  (7, 'Loja 7 - Online',     'SP');

-- Dimensao de produtos: 40 produtos em 5 categorias
CREATE OR REPLACE TABLE DIM_PRODUTO AS
SELECT SEQ4() + 1                                                   AS PRODUTO_KEY,
       'Produto ' || LPAD(SEQ4() + 1, 2, '0')                       AS NOME_PRODUTO,
       DECODE(MOD(SEQ4(), 5), 0, 'Eletronicos', 1, 'Casa', 2, 'Moda',
                              3, 'Esporte', 'Beleza')               AS CATEGORIA,
       UNIFORM(20, 2000, RANDOM(42))::NUMBER(10,2)                  AS PRECO_TABELA
FROM TABLE(GENERATOR(ROWCOUNT => 40));

-- Fato de vendas: 500 mil itens nos ultimos 365 dias
CREATE OR REPLACE TABLE FATO_VENDAS AS
WITH BASE AS (
  SELECT SEQ8() + 1                                                 AS ITEM_ID,
         DATEADD(MINUTE, -UNIFORM(0, 525600, RANDOM()), CURRENT_TIMESTAMP())::TIMESTAMP_NTZ AS DATA_HORA_VENDA,
         UNIFORM(1, 7, RANDOM())                                    AS LOJA_KEY,
         UNIFORM(1, 40, RANDOM())                                   AS PRODUTO_KEY,
         UNIFORM(1, 5, RANDOM())                                    AS QUANTIDADE
  FROM TABLE(GENERATOR(ROWCOUNT => 500000))
),
PRECOS AS (
  -- preco praticado = preco de tabela com 0 a 15% de desconto
  SELECT b.*, (p.PRECO_TABELA * UNIFORM(85, 100, RANDOM()) / 100)::NUMBER(18,2) AS PRECO_VENDIDO
  FROM BASE b
  JOIN DIM_PRODUTO p ON p.PRODUTO_KEY = b.PRODUTO_KEY
)
SELECT ITEM_ID,
       CEIL(ITEM_ID / 3)                          AS VENDA_ID,   -- ~3 itens por venda
       DATA_HORA_VENDA,
       LOJA_KEY,
       PRODUTO_KEY,
       QUANTIDADE,
       PRECO_VENDIDO,
       (QUANTIDADE * PRECO_VENDIDO)::NUMBER(18,2) AS VALOR_ITEM  -- faturamento do item
FROM PRECOS;

-- Conferindo: deve retornar 7 lojas e ~500k linhas
SELECT LOJA_KEY, COUNT(*) AS ITENS, SUM(VALOR_ITEM) AS FATURAMENTO
FROM FATO_VENDAS GROUP BY 1 ORDER BY 1;
