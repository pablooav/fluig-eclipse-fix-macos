# fluig-eclipse-fix-macos

Correções de compatibilidade para rodar o **plugin TOTVS Fluig Studio** (`com.totvs.tds.ecm.*`) no Eclipse em **macOS Apple Silicon** com **Java 17+**.

O plugin foi construído para um mundo pré-JPMS (Java 8/11). Em JDKs modernos ele quebra em pontos distintos, todos silenciosos ou com mensagens que não apontam a causa. Este repositório contém o script que aplica as correções e a documentação do *porquê* de cada uma.

```bash
./fluig-eclipse-fix.command
```

O script lista os Eclipse encontrados em `/Applications/Eclipses` e `/Applications`, pede o nome e aplica apenas o que for necessário naquela instalação.

> **Feche o Eclipse antes de rodar.** O script reempacota jars dentro de `plugins/` e limpa o cache OSGi.

---

## Índice

- [Escopo](#escopo)
- [De onde vem o JDK](#de-onde-vem-o-jdk)
- [O problema](#o-problema)
- [As correções](#as-correções)
- [Aplicação condicional](#aplicação-condicional)
- [Dependência de versão](#dependência-de-versão)
- [Matriz de homologação](#matriz-de-homologação)
- [Problemas conhecidos](#problemas-conhecidos)
- [Testes](#testes)
- [Backups e reversão](#backups-e-reversão)

---

## Escopo

Alvo: **Eclipse nativo Apple Silicon (aarch64)**, releases modernas — `Eclipse IDE 2026-03` em diante.

Fora de escopo:

- Eclipse x86_64 rodando sob Rosetta
- Releases antigas presas ao Java 8 (Neon, Oxygen e similares)
- Windows e Linux

A premissa de que o Eclipse roda sob **Java 21** vem desse recorte, e é o que torna as correções previsíveis — veja a seção seguinte.

---

## De onde vem o JDK

**O JDK vem junto com o Eclipse.** Os pacotes EPP (`Eclipse IDE for Enterprise Java and Web Developers` e afins) embarcam uma JRE **JustJ** dentro de `plugins/`, e o `eclipse.ini` aponta para ela via `-vm`. Não há instalação separada, e o JDK é atualizado pelo p2 junto com a release.

Evidência das três instalações desta máquina:

| Instalação | JRE embarcada | `-vm` no `eclipse.ini` |
|---|---|---|
| Eclipse M1 171 | `org.eclipse.justj.openjdk.hotspot.jre.full.macosx.aarch64_21.0.11` | aponta para ela |
| Eclipse M1 182 | `...aarch64_21.0.10` | aponta para ela |
| Eclipse M1 200 | `...aarch64_21.0.12` | aponta para ela |

```
-vm
../Eclipse/plugins/org.eclipse.justj.openjdk.hotspot.jre.full.macosx.aarch64_21.0.12.v20260826-1216/jre/lib/libjli.dylib
```

Os JDKs instalados em `/Library/Java/JavaVirtualMachines/` existem na máquina mas **não são usados** por estas instalações.

### O que isso significa para testes

A release do Eclipse **determina** o major do JDK. E todas as releases no escopo convergem para o mesmo:

| Release | JDK embarcado |
|---|---|
| Eclipse IDE 2026-03 | JustJ 21.x |
| Eclipse IDE 2026-06 | JustJ 21.x |
| Eclipse IDE 2026-09 | JustJ 21.x |

Ou seja: **não é necessário testar 2026-03, 2026-06 e 2026-09 separadamente** no que diz respeito ao Fix 1 — as três rodam Java 21 e se comportam igual. Só quando uma release futura subir para Java 25 é que o eixo muda e a validação precisa ser refeita.

A exceção é se você sobrescrever o `-vm` manualmente para um JDK do sistema. Aí o eixo JDK volta a ser independente da release.

---

## O problema

O Fluig Studio é distribuído como bundles OSGi que embarcam suas próprias bibliotecas em `META-INF/lib/`. Várias são de 2018 ou anteriores e assumem o modelo de acesso do Java 8: reflexão livre sobre classes do JDK, `ScriptEngine` Nashorn disponível na plataforma, e `sun.misc.Unsafe` acessível.

A partir do Java 17 o *strong encapsulation* do JPMS passou a valer por padrão, e o Nashorn foi removido do JDK no Java 15. O plugin instala, resolve e aparenta funcionar — até você tentar exportar alguma coisa.

---

## As correções

### Fix 1 — `--add-opens` no `eclipse.ini`

```
--add-opens=java.base/java.util=ALL-UNNAMED
--add-opens=java.base/java.lang=ALL-UNNAMED
--add-opens=java.base/java.lang.reflect=ALL-UNNAMED
--add-opens=java.base/java.text=ALL-UNNAMED
--add-opens=java.desktop/java.awt.font=ALL-UNNAMED
```

**Por que `java.base/java.lang` é obrigatório.** O JAX-WS RI gera classes em tempo de execução para os *wrapper beans* das operações SOAP. Quem faz isso é `com.sun.xml.ws.model.Injector`, cujo inicializador estático reflete sobre `java.lang.ClassLoader`:

| Classe interna | Reflete sobre |
|---|---|
| `Injector$1` | `java.lang.ClassLoader` → `defineClass`, `resolveClass`, `getPackage` |
| `Injector$2` | `sun.misc.Unsafe` → campo `theUnsafe` |
| `Injector$3` | `java.lang.ClassLoader.defineClass` |

Sem a flag, o `setAccessible(true)` lança `InaccessibleObjectException`, o inicializador morre, e **todo uso posterior** vira:

```
java.lang.NoClassDefFoundError: Could not initialize class com.sun.xml.ws.model.Injector
  at com.sun.xml.ws.model.WrapperBeanGenerator.createExceptionBean(...)
  at com.sun.xml.ws.model.RuntimeModeler.processRpcMethod(...)
  at ...WorkflowEngineServiceService.getWorkflowEngineServicePort(...)
  at WSMethods.getProcessVersion(WSMethods.java:786)
  at AbstractExportTotvs.doExport(AbstractExportTotvs.java:492)
  at ExportProcessWizard.performFinish(ExportProcessWizard.java:345)
```

Esse é o erro de **exportação de workflow**. A mensagem não menciona módulos nem permissões, por isso é difícil de associar à causa.

O script remove duplicatas de `--add-opens` e insere as ausentes logo após `--add-modules=ALL-SYSTEM`.

### Fix 2 — `reportNonDisposed=false`

```
-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=false
```

O SWT recente rastreia recursos gráficos não liberados e lança `java.lang.Error: SWT Resource was not properly disposed`. O plugin vaza objetos `Image` ao desenhar os ícones da árvore de servidores:

```
at org.eclipse.swt.graphics.Image.<init>(Image.java:780)
at org.eclipse.jface.resource.URLImageDescriptor.createImage(...)
at com.totvs.tds.ecm.server.ui.FluigServersExtensionView.updateServerIcon(FluigServersExtensionView.java:338)
```

A flag silencia o rastreamento. **Não corrige o vazamento** — é um paliativo para o plugin não derrubar a view.

### Fix 3 — `rt.jar`: JAX-WS RI 2.3.1 → 2.3.5

Substitui `META-INF/lib/rt.jar` dentro de `com.totvs.tds.ecm.designer.model_*.jar`.

A 2.3.1 é de 2018 e antecede o endurecimento do JPMS. O script lê o `Build-Version` do manifesto, baixa de `repo1.maven.org` **apenas se necessário**, e pula se já estiver em 2.3.5.

### Fix 4 — Nashorn standalone no `Bundle-ClassPath`

Injeta `nashorn-core-15.4.jar` + as quatro dependências ASM em `com.totvs.tds.ecm.designer.eclipse_*.jar` e as declara no `Bundle-ClassPath`.

O Nashorn foi **removido do JDK no Java 15** (JEP 372). Versões antigas do plugin chamam `new ScriptEngineManager().getEngineByName("js")` e recebem `null`.

**Aplicado condicionalmente** — veja a seção seguinte.

### Fix 5 — Limpeza do cache OSGi

```
rm -rf <Eclipse>/configuration/org.eclipse.osgi
```

O Equinox persiste o estado de resolução dos bundles. Depois de reempacotar jars, o cache precisa ser invalidado — caso contrário o `Bundle-ClassPath` antigo continua valendo e os Fix 3 e 4 não têm efeito.

---

## Aplicação condicional

O script **detecta capacidade, não compara número de versão**. Isso é mais robusto: a TOTVS muda o conteúdo dos bundles entre builds sem alterar o esquema de versionamento de forma previsível.

| Fix | Condição para aplicar | Se não aplicável |
|---|---|---|
| 1 | flag ausente do `eclipse.ini` | não reescreve |
| 2 | `reportNonDisposed` ausente ou `=true` | não reescreve |
| 3 | `Build-Version` do `rt.jar` ≠ `JAX-WS RI 2.3.5` | **não baixa nada** |
| 4 | plugin **não** embarca motor JS próprio **e** `nashorn-core.jar` ausente | **não baixa nada** |

### A regra do Fix 4

A partir da 1.8.2.x a TOTVS passou a embarcar o Rhino no próprio plugin. Quando já existe motor JS, injetar Nashorn é desnecessário e ainda registra dois engines concorrentes via `ServiceLoader`.

A detecção procura `META-INF/lib/*rhino*.jar` dentro do bundle:

| Plugin | Motor JS embarcado | Decisão |
|---|---|---|
| 1.7.1.3 | *(nenhum)* | **aplica** Fix 4 |
| 1.8.2.5 | `rhino-js-engine.jar`, `rhino.jar` | **pula** — nada é baixado |
| 2.0.0.9 | `fluig-rhino.jar`, `rhino-js-engine.jar` | **pula** — nada é baixado |

Na prática, `nashorn-core` + 4 jars ASM (~5 MB) deixam de ser baixados nas versões 1.8.x e 2.0.x.

---

## Dependência de versão

**Não é a release do Eclipse que determina o que aplicar.**

| Fix | Depende de | A release do Eclipse importa? |
|---|---|---|
| 1 — `--add-opens` | major do **JDK** | Sim, indiretamente: a release traz a JustJ |
| 2 — `reportNonDisposed` | versão do **SWT** | Sim, mas inofensivo em versões antigas |
| 3 — `rt.jar` | versão do **plugin Fluig** | Não |
| 4 — Nashorn | **conteúdo do bundle** do plugin | Não |
| 5 — cache OSGi | — | Não: o caminho é estável desde o Eclipse 3.x |

### Evidência

Três instalações desta máquina são **todas Eclipse 4.39.0**, com plugins diferentes:

| Instalação | Eclipse | Plugin Fluig |
|---|---|---|
| Eclipse M1 171 | 4.39.0 | 1.7.1.3 |
| Eclipse M1 182 | 4.39.0 | 1.8.2.5 |
| Eclipse M1 200 | 4.39.0 | 2.0.0.9 |

Mesmo Eclipse, mesma JustJ 21, e mesmo assim **exigem patches diferentes** — porque o que varia é o plugin.

### Quanto testar

Combinações relevantes: `(major do JDK) × (versão do plugin Fluig)`.

Como todas as releases no escopo embarcam JustJ 21, o eixo JDK está **fixo hoje**. Na prática você só precisa validar por **versão de plugin**. Uma release nova do Eclipse que continue em Java 21 e use um plugin já homologado é risco baixo: teste de fumaça basta.

---

## Matriz de homologação

Legenda: ✅ validado · ⏭️ pulado por detecção (comportamento correto) · ⬜ não testado

| Eclipse | JDK (JustJ) | Plugin | Fix 1 | Fix 2 | Fix 3 | Fix 4 | Export workflow |
|---|---|---|---|---|---|---|---|
| 4.39.0 | 21.0.12 | 2.0.0.9 | ✅ | ✅ | ⬜ | ⏭️ | ⬜ |
| 4.39.0 | 21.0.10 | 1.8.2.5 | ✅ | ✅ | ✅ | ⏭️ | ⬜ |
| 4.39.0 | 21.0.11 | 1.7.1.3 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |

Atualize a cada combinação testada. Esta tabela é o contrato do que não pode regredir.

---

## Problemas conhecidos

### 1. Crash nativo SWT/Cocoa (não endereçado)

Em uso prolongado o Eclipse pode cair com:

```
SIGSEGV em objc_release
  libobjc.A.dylib          objc_release
  Foundation               -[NSAutoreleasePool release]
  libswt-pi-cocoa          OS.objc_msgSend
  org.eclipse.swt.widgets.Display.removePool()
  org.eclipse.swt.widgets.Display.readAndDispatch()
```

Problema do SWT no macOS ARM, fora do escopo deste script. O Fix 2 silencia o *aviso* de recursos não liberados, mas não a liberação dupla no lado nativo.

### 2. Atualização do plugin desfaz os Fix 3 e 4

Atualizar o Fluig Studio pelo p2 **substitui os jars** e reverte os patches. Depois de toda atualização, rode o script de novo. A atualização 2.0.0.8 → 2.0.0.9 reverteu o `rt.jar` para 2.3.1.

### 3. Nashorn vs. Rhino não verificado em runtime

A detecção do Fix 4 assume que, se o plugin embarca Rhino, ele resolve o `ScriptEngine` por ele. Isso é inferido do conteúdo do bundle, **não observado em execução**. Se aparecer falha de script em 1.8.x ou 2.0.x, vale confirmar qual engine é resolvido antes de concluir que o Fix 4 era necessário.

---

## Histórico de correções no próprio script

| Data | Correção |
|---|---|
| 2026-11-17 | `java.base/java.lang` adicionado ao Fix 1 — sem ele a exportação de workflow falha |
| 2026-11-17 | Fix 4 passa a detectar motor JS embarcado e pular quando desnecessário |
| 2026-11-17 | Fix 4 passa a desdobrar o `MANIFEST.MF` antes de procurar a âncora e a redobrar em 72 bytes |

O desdobramento era necessário porque a spec JAR limita linhas do manifesto a 72 bytes. Na 2.0.0.9 a âncora `META-INF/lib/jaxws-api.jar` caía exatamente sobre uma dobra:

```
53: TA-INF/lib/guava.jar,META-INF/lib/wcm-common.jar,META-INF/lib/jaxws-api
54: .jar,META-INF/lib/foundation-script-runner.jar
```

A busca pela string contígua falhava e o Fix 4 abortava em silêncio.

---

## Testes

Planejado, ainda não implementado. O objetivo é garantir que uma correção nova não quebre combinação já homologada, rodando contra **fixtures sintéticas** — árvores `<nome>.app/Contents/Eclipse/` em diretório temporário — sem tocar instalações reais.

Casos previstos:

- `eclipse.ini` sem flags → as 5 são inseridas após `--add-modules`
- `eclipse.ini` completo → idempotente, sem duplicatas
- `eclipse.ini` com duplicatas → deduplicado
- jar com `rt.jar` 2.3.1 → vira 2.3.5, zip válido, demais entradas intactas
- jar com `rt.jar` 2.3.5 → pulado, nada baixado
- jar com Rhino embarcado → Fix 4 pulado, nada baixado
- manifesto com âncora dobrada → Fix 4 encontra e aplica, linhas ≤ 72 bytes
- jar sem âncora → aborta sem corromper o jar

Para a suíte invocar o script real é preciso um gancho de override do caminho da instalação (hoje `SEARCH_DIRS` é fixo em `/Applications`) e um modo não interativo.

---

## Backups e reversão

| Arquivo | Backup |
|---|---|
| `eclipse.ini` | `eclipse.ini.bak` |
| `com.totvs.tds.ecm.designer.model_*.jar` | `<mesmo nome>.jar.bak` |
| `com.totvs.tds.ecm.designer.eclipse_*.jar` | `<mesmo nome>.jar.bak.nashorn` |

Backups existentes **não são sobrescritos** — o primeiro é sempre preservado como estado original.

Para reverter, restaure os `.bak` e apague `configuration/org.eclipse.osgi`.

---

## Requisitos

- macOS Apple Silicon
- `curl`, `zip`, `unzip`, `python3`
- Acesso ao Maven Central — somente quando algum download for de fato necessário
