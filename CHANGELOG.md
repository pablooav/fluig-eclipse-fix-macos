# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/);
versionamento conforme [SemVer](https://semver.org/lang/pt-BR/).

## [1.0.1] — 2026-11-23

### Corrigido

- **O Fix 4 corrompia o `MANIFEST.MF` e inutilizava o bundle.** Ao redobrar o
  manifesto, as quebras CRLF não eram normalizadas antes do fatiamento: cada
  linha ficava com um `\r` sobrando e o `join` com `\r\n` produzia `\r\r\n`.
  Pela spec do JAR, esse `\r` extra vale como uma **linha em branco** — e linha
  em branco encerra a seção principal do manifesto. O Equinox parava de enxergar
  o `Bundle-SymbolicName`, o bundle `com.totvs.tds.ecm.designer.eclipse` não
  resolvia mais, e com ele caíam os ícones, as views e o editor gráfico do
  Graphiti — o diagrama deixava de abrir e o processo era exibido como XML cru.

  Atingia **apenas instalações em que o Fix 4 chega a ser aplicado**, ou seja,
  plugin sem motor JS embarcado (1.7.x). Nas versões 1.8.x e 2.0.x o Fix 4 é
  pulado e a 1.0.0 não causava dano.

  **Se você rodou a 1.0.0 num plugin 1.7.x**, restaure o backup e rode de novo:

  ```bash
  cd "/Applications/<SEU-ECLIPSE>.app/Contents/Eclipse"
  cp plugins/com.totvs.tds.ecm.designer.eclipse_*.jar.bak.nashorn \
     plugins/com.totvs.tds.ecm.designer.eclipse_1.7.1.3.jar
  rm -rf configuration/org.eclipse.osgi
  ```

### Testes

- A suíte lia o manifesto em modo texto, onde o Python normaliza `\r\r\n` em
  silêncio — foi esse ponto cego que deixou o bug passar. Agora há um validador
  que lê os **bytes crus** e aplica as regras da spec: fim de linha, limite de
  72 bytes por linha física, e presença de `Manifest-Version`,
  `Bundle-SymbolicName` e `Bundle-ClassPath` dentro da seção principal.
- Caso novo `fix4_preserva_fim_de_linha`. Contra o script da 1.0.0 ele reprova
  com `header fora da secao principal: Bundle-SymbolicName` — exatamente o que
  o Equinox relatou em produção.
- 25 casos e 128 asserções.

### Validado

- **Primeira validação em runtime do Fix 4**, em Eclipse 4.39.0 / JustJ 21.0.11
  / plugin 1.7.1.3. A exportação de workflow acusava
  `Ocorreu erro de sintaxe no(s) seguinte(s) evento(s)` listando **todos** os
  eventos, inclusive os corretos. A causa está no bytecode do plugin:
  `AbstractExportTotvs.checkEventsErros()` faz
  `new ScriptEngineManager().getEngineByName("js")`, recebe `null` em Java 21
  (Nashorn removido na JEP 372), e o `catch (Exception)` do laço converte o
  `NullPointerException` em "erro de sintaxe" para cada evento. Depois do
  Fix 4, `getEngineByName("js")` devolve `NashornScriptEngine` e a exportação
  conclui.
- As versões 1.8.2.5 e 2.0.0.9 não dependem disso: embarcam
  `rhino-js-engine.jar`, que registra um `javax.script.ScriptEngineFactory`
  própria. Confirmado também no backup pré-fix do 1.8.2.5 — o Rhino já estava
  lá de fábrica.
- Matriz de homologação atualizada: linha 1.7.1.3 completa, coluna
  **Export workflow** validada nas três versões de plugin.

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

[1.0.1]: https://github.com/pablooav/fluig-eclipse-fix-macos/releases/tag/v1.0.1
[1.0.0]: https://github.com/pablooav/fluig-eclipse-fix-macos/releases/tag/v1.0.0
