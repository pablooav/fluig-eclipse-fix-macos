# fluig-eclipse-fix-macos

Correções de compatibilidade para rodar o **plugin TOTVS Fluig Studio** (`com.totvs.tds.ecm.*`) no Eclipse em **macOS Apple Silicon** com **Java 17+**.

O plugin foi construído para um mundo pré-JPMS (Java 8/11). Em JDKs modernos ele quebra em quatro pontos distintos, todos silenciosos ou com mensagens que não apontam a causa. Este repositório contém o script que aplica as correções e a documentação do *porquê* de cada uma.

```bash
./fluig-eclipse-fix.command
```

O script lista os Eclipse encontrados em `/Applications/Eclipses` e `/Applications`, pede o nome e aplica as correções naquela instalação.

> **Feche o Eclipse antes de rodar.** O script reempacota jars dentro de `plugins/` e limpa o cache OSGi.

---

## Índice

- [O problema](#o-problema)
- [As correções](#as-correções)
- [Dependência de versão](#dependência-de-versão)
- [Matriz de homologação](#matriz-de-homologação)
- [Problemas conhecidos](#problemas-conhecidos)
- [Testes](#testes)
- [Backups e reversão](#backups-e-reversão)

---

## O problema

O Fluig Studio é distribuído como um conjunto de bundles OSGi que embarcam suas próprias bibliotecas em `META-INF/lib/`. Várias delas são de 2018 ou anteriores e assumem o modelo de acesso do Java 8: reflexão livre sobre classes do JDK, `ScriptEngine` Nashorn disponível na plataforma, e `sun.misc.Unsafe` acessível.

A partir do Java 17 o *strong encapsulation* do JPMS passou a valer por padrão, e o Nashorn foi removido do JDK no Java 15. O resultado prático é que o plugin instala, resolve e aparenta funcionar — até você tentar exportar alguma coisa.

---

## As correções

### Fix 1 — `--add-opens` no `eclipse.ini`

Abre pacotes do JDK para reflexão não-modular.

```
--add-opens=java.base/java.util=ALL-UNNAMED
--add-opens=java.base/java.lang=ALL-UNNAMED
--add-opens=java.base/java.lang.reflect=ALL-UNNAMED
--add-opens=java.base/java.text=ALL-UNNAMED
--add-opens=java.desktop/java.awt.font=ALL-UNNAMED
```

**Por que `java.base/java.lang` é obrigatório.** O JAX-WS RI gera classes em tempo de execução para os *wrapper beans* das operações SOAP. Quem faz isso é `com.sun.xml.ws.model.Injector`, e o inicializador estático dele reflete sobre `java.lang.ClassLoader`:

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

O script remove duplicatas de `--add-opens` e insere as ausentes logo após `--add-modules=ALL-SYSTEM`. Se essa âncora não existir, anexa ao fim do arquivo.

> ⚠️ `--add-opens` **não existe no Java 8**. Aplicar em um Eclipse que roda sob JDK 8 faz a JVM recusar a inicialização com *Unrecognized option*. Veja [Problemas conhecidos](#problemas-conhecidos).

### Fix 2 — `reportNonDisposed=false`

```
-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=false
```

O SWT recente rastreia recursos gráficos não liberados e lança `java.lang.Error: SWT Resource was not properly disposed`. O plugin vaza objetos `Image` ao desenhar os ícones da árvore de servidores:

```
at org.eclipse.swt.graphics.Image.<init>(Image.java:780)
at org.eclipse.jface.resource.URLImageDescriptor.createImage(...)
at com.totvs.tds.ecm.server.ui.FluigServersExtensionView.updateServerIcon(FluigServersExtensionView.java:338)
at ...FluigServersExtensionView.readTreeViewMap(FluigServersExtensionView.java:167)
```

A flag silencia o rastreamento. **Não corrige o vazamento** — é um paliativo para o plugin não derrubar a view.

### Fix 3 — `rt.jar`: JAX-WS RI 2.3.1 → 2.3.5

Substitui `META-INF/lib/rt.jar` dentro de `com.totvs.tds.ecm.designer.model_*.jar`.

A 2.3.1 é de 2018 e antecede o endurecimento do JPMS. A 2.3.5 trata melhor JDKs modernos. O script baixa de:

```
https://repo1.maven.org/maven2/com/sun/xml/ws/rt/2.3.5/rt-2.3.5.jar
```

Verifica o `Build-Version` do manifesto antes e depois, e pula se já estiver em 2.3.5.

### Fix 4 — Nashorn standalone no `Bundle-ClassPath`

Injeta `nashorn-core-15.4.jar` + as quatro dependências ASM (`asm`, `asm-commons`, `asm-tree`, `asm-util`) em `com.totvs.tds.ecm.designer.eclipse_*.jar` e os declara no `Bundle-ClassPath` do manifesto.

O Nashorn foi **removido do JDK no Java 15** (JEP 372). Versões antigas do plugin chamam `new ScriptEngineManager().getEngineByName("js")` e recebem `null`.

> ⚠️ Esta correção pode ser **obsoleta** a partir da 1.8.2.x. Veja [Problemas conhecidos](#problemas-conhecidos).

### Fix 5 — Limpeza do cache OSGi

```
rm -rf <Eclipse>/configuration/org.eclipse.osgi
```

O Equinox persiste o estado de resolução dos bundles. Depois de reempacotar jars, o cache precisa ser invalidado — caso contrário o `Bundle-ClassPath` antigo continua valendo e os Fix 3 e 4 não têm efeito. O cache é recriado na próxima inicialização, que fica mais lenta.

---

## Dependência de versão

**Resposta curta: não é a release do Eclipse que determina a compatibilidade.** São dois outros eixos.

| Fix | Depende de | A release do Eclipse importa? |
|---|---|---|
| 1 — `--add-opens` | Versão do **Java** | Só indiretamente: define sob qual JDK o Eclipse roda |
| 2 — `reportNonDisposed` | Versão do **SWT** | Sim, mas é inofensivo em versões antigas (propriedade desconhecida é ignorada) |
| 3 — `rt.jar` | Versão do **plugin Fluig** | Não |
| 4 — Nashorn | Versão do **plugin** + Java ≥ 15 | Não |
| 5 — cache OSGi | — | Não: o caminho `configuration/org.eclipse.osgi` é estável desde o Eclipse 3.x |

### Evidência

Três instalações desta máquina são **todas Eclipse 4.39.0** (`org.eclipse.platform`), com plugins diferentes:

| Instalação | Eclipse | Plugin Fluig | `--add-modules` no ini |
|---|---|---|---|
| Eclipse M1 171 | 4.39.0 | 1.7.1.3 | sim |
| Eclipse M1 182 | 4.39.0 | 1.8.2.5 | sim |
| Eclipse M1 200 | 4.39.0 | 2.0.0.9 | sim |
| Eclipse Neon 182 | **4.6.3** | 1.8.2.3 | **não** |

Ou seja: o que varia para os Fix 3 e 4 é o **plugin**, não o Eclipse. As três instalações 4.39.0 exigem patches diferentes porque embarcam versões diferentes do plugin.

O Neon é o contraexemplo em todos os sentidos — Eclipse 4.6.3, sem `--add-modules`, e preso ao JDK 8:

```
-vm /Library/Java/JavaVirtualMachines/jdk1.8.0_301.jdk/Contents/Home/bin/java
-Dosgi.requiredJavaVersion=1.8
```

### O que isso significa na prática

Você **não precisa testar cada release do Eclipse**. Precisa testar as combinações de:

1. **Major do JDK** sob o qual o Eclipse roda — 8, 11, 17, 21, 25
2. **Versão do plugin Fluig** — 1.7.x, 1.8.x, 2.0.x

A release do Eclipse entra como terceiro eixo apenas quando muda o JDK mínimo exigido (o que troca o eixo 1) ou quando o SWT muda comportamento relevante (eixo do Fix 2).

Uma release nova do Eclipse rodando o mesmo JDK e o mesmo plugin de uma combinação já homologada tem **risco baixo** — vale um teste de fumaça, não uma rodada completa.

---

## Matriz de homologação

Legenda: ✅ validado · ⚠️ validado com ressalva · ❌ quebra · ⬜ não testado

| Eclipse | JDK | Plugin | Fix 1 | Fix 2 | Fix 3 | Fix 4 | Export workflow |
|---|---|---|---|---|---|---|---|
| 4.39.0 | JustJ 21.0.12 | 2.0.0.9 | ✅ | ✅ | ⬜ | ❌ | ⬜ |
| 4.39.0 | Temurin 21.0.10 | 1.8.2.5 | ✅ | ✅ | ✅ | ✅ | ⬜ |
| 4.39.0 | Temurin 21 | 1.7.1.3 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| 4.6.3 (Neon) | Oracle 1.8.0_301 | 1.8.2.3 | ❌ | ⚠️ | ⬜ | ⬜ | ⬜ |

Atualize esta tabela a cada combinação testada. Ela é o contrato do que não pode regredir.

---

## Problemas conhecidos

### 1. Fix 4 aborta na 2.0.0.9 — manifesto dobrado

O patch do `Bundle-ClassPath` procura a string literal `META-INF/lib/jaxws-api.jar` no `MANIFEST.MF` **cru**, sem desdobrar as continuações de linha.

A especificação JAR limita linhas do manifesto a 72 bytes, e continuações começam com um espaço. Na 2.0.0.9 a âncora cai exatamente em cima de uma quebra:

```
53: TA-INF/lib/guava.jar,META-INF/lib/wcm-common.jar,META-INF/lib/jaxws-api
54: .jar,META-INF/lib/foundation-script-runner.jar
```

A string contígua não existe no arquivo, e o Fix 4 encerra com:

```
ERRO: 'jaxws-api.jar' nao encontrado no Bundle-ClassPath.
```

**Impacto:** o Fix 4 é silenciosamente pulado nas versões em que a âncora cai numa dobra. O comportamento depende do comprimento acumulado da linha, ou seja, de quais libs vêm antes — pode mudar entre builds do plugin sem aviso.

**Correção proposta:** desdobrar o manifesto (`re.sub(r'\r?\n ', '', conteudo)`) antes de procurar, e **redobrar em 72 bytes** ao gravar.

### 2. Fix 4 pode ser desnecessário a partir da 1.8.2.x

Inventário do que cada versão embarca em `META-INF/lib/`:

| Plugin | Motor JS embarcado |
|---|---|
| 1.7.1.3 | *(nenhum — depende do Nashorn do JDK)* |
| 1.8.2.5 | `rhino-js-engine.jar`, `rhino.jar` |
| 2.0.0.9 | `fluig-rhino.jar`, `rhino-js-engine.jar` |

A TOTVS passou a embarcar **Rhino**. Se o plugin resolve o `ScriptEngine` pelo Rhino próprio, injetar Nashorn é inócuo — ou pior, pode criar ambiguidade entre dois engines registrados.

**Status: não verificado.** Falta confirmar qual engine o plugin realmente resolve em tempo de execução nas versões 1.8.2.x e 2.0.x. Até lá, o Fix 4 segue aplicável apenas à 1.7.x com certeza.

### 3. Sem proteção contra Eclipse em Java 8

O script não verifica sob qual JDK a instalação roda antes de inserir `--add-opens`. Aplicar no Neon (JDK 8) **impede o Eclipse de iniciar**.

**Correção proposta:** abortar quando o `eclipse.ini` contiver `-Dosgi.requiredJavaVersion=1.8` ou quando o `-vm` apontar para um JDK 8.

### 4. Crash nativo SWT/Cocoa (não endereçado)

Em uso prolongado o Eclipse pode cair com:

```
SIGSEGV em objc_release
  libobjc.A.dylib          objc_release
  Foundation               -[NSAutoreleasePool release]
  libswt-pi-cocoa          OS.objc_msgSend
  org.eclipse.swt.widgets.Display.removePool()
  org.eclipse.swt.widgets.Display.readAndDispatch()
```

É um problema do SWT no macOS ARM, fora do escopo deste script. O Fix 2 silencia o *aviso* de recursos não liberados, mas não a liberação dupla no lado nativo.

---

## Testes

Veja [`tests/README.md`](tests/README.md).

```bash
./tests/run-tests.sh
```

O objetivo é garantir que uma correção nova não quebre combinação já homologada. A suíte roda contra **fixtures sintéticas** — árvores `<nome>.app/Contents/Eclipse/` montadas em diretório temporário — e nunca toca instalações reais.

---

## Backups e reversão

O script cria backups antes de cada alteração destrutiva:

| Arquivo | Backup |
|---|---|
| `eclipse.ini` | `eclipse.ini.bak` |
| `com.totvs.tds.ecm.designer.model_*.jar` | `<mesmo nome>.jar.bak` |
| `com.totvs.tds.ecm.designer.eclipse_*.jar` | `<mesmo nome>.jar.bak.nashorn` |

Backups existentes **não são sobrescritos** — o primeiro é sempre preservado como estado original.

Para reverter, restaure os `.bak` e apague `configuration/org.eclipse.osgi`.

> Atualizar o plugin pelo p2 **substitui os jars** e desfaz os Fix 3 e 4. Depois de toda atualização do Fluig Studio, rode o script de novo.

---

## Requisitos

- macOS (testado em Apple Silicon)
- `curl`, `zip`, `unzip`, `python3`
- Acesso ao Maven Central (o script baixa `rt.jar`, `nashorn-core` e ASM)
