# Snowflake — Código dos artigos de Dhiego Piroto

Código e explicações complementares dos meus artigos sobre Snowflake (Medium / WordPress).
Cada pasta na raiz é um projeto autocontido: setup → execução → teardown.

## Projetos

| Projeto | Artigo | Versão |
|---|---|---|
| _(em breve)_ | | |

## Como usar

- **Local:** `git clone` → entre na pasta do projeto → siga o `README.md` dele.
- **Snowflake Workspaces:** Snowsight » Projects » Workspaces » *From Git repository*
  (requer API integration — ver [`shared/sql/git_integration.sql`](shared/sql/git_integration.sql)).
- **Direto do Git no Snowflake:**
  `EXECUTE IMMEDIATE FROM @<db>.GIT.SNOWFLAKE_LABS/tags/<projeto>/vX.Y.Z/<projeto>/sql/00_setup.sql;`

## Novo projeto

```bash
cp -R shared/template meu-projeto
# substitua __NAME__ / __UNAME__ / __DATE__ nos arquivos
```

## Convenções

- Commits: [Conventional Commits](https://www.conventionalcommits.org/) com escopo = projeto (`feat(meu-projeto): ...`).
- Tags por projeto: `<projeto>/vX.Y.Z`. **Artigos linkam a tag, não a `main`.**
- Nada de credenciais no repositório (`.gitignore` + pre-commit com gitleaks).

## Licença

Apache-2.0 — código de exemplo fornecido "as is", sem garantias.
