"""Relatorio de Vendas - versao OWNER'S RIGHTS.

Todas as queries rodam com a role DONA do app (ACCOUNTADMIN neste tutorial),
entao qualquer pessoa que abrir o app ve exatamente os mesmos dados.
"""
import altair as alt
import streamlit as st

st.set_page_config(page_title="Relatório de Vendas", page_icon=":bar_chart:", layout="wide")
st.title("Relatório de Vendas")

# Conexao padrao do Streamlit in Snowflake = direitos do owner
conn = st.connection("snowflake")

FROM = """
FROM EMBED_DEMO.GOLD.FATO_VENDAS f
JOIN EMBED_DEMO.GOLD.DIM_LOJA    l ON l.LOJA_KEY    = f.LOJA_KEY
JOIN EMBED_DEMO.GOLD.DIM_PRODUTO p ON p.PRODUTO_KEY = f.PRODUTO_KEY
"""


@st.cache_data(ttl=600, show_spinner=False)
def q(sql: str):
    return conn.query(sql, ttl=0)


def brl(v) -> str:
    v = 0 if v is None or v != v else float(v)  # NULL (masking) vira 0
    return "R$ " + f"{v:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


kpi = q(f"""SELECT SUM(f.VALOR_ITEM) AS FATURAMENTO, COUNT(DISTINCT f.VENDA_ID) AS VENDAS,
                   SUM(f.QUANTIDADE) AS ITENS, COUNT(DISTINCT f.LOJA_KEY) AS LOJAS {FROM}""").iloc[0]
c1, c2, c3, c4 = st.columns(4)
c1.metric("Faturamento", brl(kpi["FATURAMENTO"]), border=True)
c2.metric("Vendas", f"{int(kpi['VENDAS']):,}".replace(",", "."), border=True)
c3.metric("Itens", f"{int(kpi['ITENS']):,}".replace(",", "."), border=True)
c4.metric("Lojas", int(kpi["LOJAS"]), border=True)

mes = q(f"""SELECT DATE_TRUNC('month', f.DATA_HORA_VENDA)::DATE AS MES,
                   SUM(f.VALOR_ITEM) AS FATURAMENTO, SUM(f.QUANTIDADE) AS ITENS
            {FROM} GROUP BY 1 ORDER BY 1""")
st.altair_chart(alt.Chart(mes).mark_line(point=True).encode(
    x=alt.X("MES:T", title=None), y=alt.Y("ITENS:Q", title="Itens vendidos"),
    tooltip=["MES:T", "ITENS:Q", "FATURAMENTO:Q"]).properties(title="Itens vendidos por mês", height=280),
    use_container_width=True)

col_a, col_b = st.columns(2)
loja = q(f"SELECT l.NOME_LOJA, SUM(f.VALOR_ITEM) AS FATURAMENTO, SUM(f.QUANTIDADE) AS ITENS {FROM} GROUP BY 1 ORDER BY 1")
col_a.altair_chart(alt.Chart(loja).mark_bar().encode(
    x=alt.X("ITENS:Q", title="Itens"), y=alt.Y("NOME_LOJA:N", title=None, sort="-x"),
    tooltip=["NOME_LOJA", "ITENS", "FATURAMENTO"]).properties(title="Itens por loja", height=280),
    use_container_width=True)

cat = q(f"SELECT p.CATEGORIA, SUM(f.VALOR_ITEM) AS FATURAMENTO {FROM} GROUP BY 1 ORDER BY 2 DESC")
col_b.altair_chart(alt.Chart(cat).mark_arc(innerRadius=60).encode(
    theta="FATURAMENTO:Q", color="CATEGORIA:N",
    tooltip=["CATEGORIA", "FATURAMENTO"]).properties(title="Faturamento por categoria", height=280),
    use_container_width=True)
