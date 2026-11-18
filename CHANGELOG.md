# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/);
versionamento conforme [SemVer](https://semver.org/lang/pt-BR/).

## [1.0.0] — 2026-11-17

Primeira versão pública.

### Correções aplicadas ao Eclipse

- **Fix 1** — insere as cinco flags `--add-opens` necessárias no `eclipse.ini`,
  removendo duplicatas. Inclui `java.base/java.lang`, sem a qual a exportação de
  workflow falha com `NoClassDefFoundError: Could not initialize class
  com.sun.xml.ws.model.Injector`.
- **Fix 2** — garante `reportNonDisposed=false` e remove ocorrências repetidas
  da flag, evitando que o vazamento de `Image` do plugin derrube a árvore de
  servidores.
- **Fix 3** — substitui o `rt.jar` (JAX-WS RI 2.3.1, de 2018) pelo 2.3.5 dentro
  de `com.totvs.tds.ecm.designer.model_*.jar`.
- **Fix 4** — injeta `nashorn-core` e as dependências ASM no `Bundle-ClassPath`
  de `com.totvs.tds.ecm.designer.eclipse_*.jar`, **apenas** quando o plugin não
  embarca motor JS próprio.
- **Fix 5** — limpa o cache OSGi para que os Fix 3 e 4 tenham efeito.

### Aplicação condicional

Todas as correções são aplicadas por **detecção de capacidade**, não por
comparação de número de versão. Nas versões 1.8.x e 2.0.x do plugin, que já
embarcam Rhino, o Fix 4 é pulado e os ~5 MB de `nashorn-core` + ASM não são
baixados.

### Interface

- Modo interativo (duplo clique no Finder) e modo automatizado:
  `--eclipse`, `--non-interactive`, `--offline`, `--cache-dir`,
  `--search-dirs`, `--report`, `--help`, `--version`.
- Relatório `chave=valor` com o status de cada correção.
- Códigos de saída: `0` tudo certo · `1` alguma correção falhou · `2` erro de
  uso ou pré-requisito ausente.
- Cada correção é independente: a falha de uma não aborta as demais, e o resumo
  final mostra o status real de cada uma.

### Backups

`eclipse.ini.bak`, `<plugin>.jar.bak` e `<plugin>.jar.bak.nashorn`. Backups
existentes nunca são sobrescritos — o primeiro é preservado como estado
original, mesmo em execuções repetidas.

### Qualidade

- Suíte de 24 casos e 121 asserções, sem necessidade de Eclipse instalado e sem
  acesso à rede, validada por mutação.
- CI no GitHub Actions: lint e testes em macOS e Linux a cada pull request.

### Notas

Durante o desenvolvimento foram corrigidos bugs no próprio script — entre eles
a detecção do `rt.jar` por pipe, que falhava sempre em silêncio, e a busca da
âncora em manifestos dobrados em 72 bytes. O detalhe de cada um está na seção
[Histórico de correções no próprio script](README.md#histórico-de-correções-no-próprio-script)
do README.

[1.0.0]: https://github.com/pablooav/fluig-eclipse-fix-macos/releases/tag/v1.0.0
