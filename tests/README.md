# Suíte de testes

```bash
./tests/run-tests.sh            # 25 casos, 128 asserções
./tests/run-tests.sh fix4       # só os casos cujo nome contém "fix4"
KEEP_FIXTURES=1 ./tests/run-tests.sh   # preserva o sandbox para inspeção
```

Saída: `0` se tudo passou, `1` se algum caso falhou, `2` se faltou dependência.

## Como funciona

A suíte **não precisa de Eclipse instalado e não acessa a rede.**

Cada caso monta, num diretório temporário, uma instalação de Eclipse sintética:

```
$TMPDIR/fluig-fix-tests.XXXX/
├── cache/                              ← "Maven Central" falso
│   ├── jaxws-rt-2.3.5.jar
│   ├── nashorn-core-15.4.jar
│   └── fluig_asm/{asm,asm-commons,asm-tree,asm-util}.jar
└── caso.XXXX/
    └── Eclipse Teste 2026-03.app/Contents/Eclipse/
        ├── eclipse.ini
        ├── configuration/org.eclipse.osgi/
        └── plugins/
            ├── com.totvs.tds.ecm.designer.model_<v>.jar    ← contém META-INF/lib/rt.jar
            └── com.totvs.tds.ecm.designer.eclipse_<v>.jar  ← manifesto com Bundle-ClassPath
```

O script roda com `--non-interactive --offline --eclipse <path> --search-dirs <sandbox>
--cache-dir <cache> --report <arquivo>`. O `--search-dirs` garante que `/Applications`
nunca seja tocado; o `--offline` garante que nenhum byte saia pela rede.

As asserções leem o arquivo de `--report`, que é um `chave=valor` simples:

```
eclipse=/.../Eclipse Teste 2026-03.app
plugin_versao=2.0.0.9
rt_versao_antes=JAX-WS RI 2.3.5
fix1=aplicado
fix2=inalterado
fix3=ja-atualizado
fix4=pulado-rhino
fix4_motor=META-INF/lib/fluig-rhino.jar META-INF/lib/rhino-js-engine.jar
fix5=aplicado
status=concluido
```

Conferir o relatório em vez do texto dos logs deixa os testes imunes a mudanças
de redação nas mensagens.

## Arquivos

| Arquivo | Papel |
|---|---|
| `run-tests.sh` | Casos + runner |
| `lib/assert.sh` | `assert_eq`, `assert_count`, `assert_same_file`, … |
| `lib/fixtures.sh` | Constrói `.app`, `eclipse.ini` e jars sintéticos |
| `lib/mkmanifest.py` | Gera `MANIFEST.MF` com dobra de 72 bytes conforme a spec JAR |

### Variantes de `eclipse.ini`

`completo` (EPP 2026-x padrão) · `sem-modules` (sem `--add-modules=ALL-SYSTEM`) ·
`swt-true` · `swt-ausente` · `duplicado` (flags repetidas)

### Variantes do bundle `designer.eclipse`

| Flavor | O que simula | Fix 4 esperado |
|---|---|---|
| `plain` | plugin antigo, sem motor JS | aplica |
| `folded` | âncora `jaxws-api.jar` partida por uma dobra de 72 bytes | aplica |
| `rhino` | 1.8.2.x / 2.0.x, com Rhino embarcado | pula |
| `nashorn` | fix já aplicado antes | pula |
| `no-anchor` | `Bundle-ClassPath` sem a âncora | falha controlada |

O flavor `folded` é gerado por busca: `mkmanifest.py` insere entradas de
preenchimento até a âncora **de fato** cruzar um limite de dobra, e o próprio
caso de teste confirma isso antes de rodar o script. Sem essa confirmação, o
teste poderia passar sem exercitar nada.

## Casos cobertos

| # | Caso | O que trava |
|---|---|---|
| 1 | `fix1_instalacao_limpa` | as 5 flags entram, uma vez cada, após `--add-modules` |
| 2 | `fix1_idempotente` | 2ª execução não muda nada e não sobrescreve o `.bak` |
| 3 | `fix1_sem_add_modules` | sem a âncora, as flags vão para o fim do arquivo |
| 4 | `fix1_colapsa_duplicatas` | flags repetidas viram uma só |
| 5 | `fix2_true_vira_false` | `reportNonDisposed=true` → `false` |
| 6 | `fix2_flag_ausente` | flag é adicionada |
| 7 | `fix2_ja_false` | nada a fazer é reportado como `inalterado` |
| 8 | `fix3_patch_rt_jar` | 2.3.1 → 2.3.5, backup correto, demais entradas preservadas |
| 9 | `fix3_ja_atualizado_nao_reaplica` | detecta 2.3.5 e não mexe no jar |
| 10 | `fix4_aplica_sem_motor_js` | 5 libs entram no jar e no `Bundle-ClassPath`, ≤72 bytes/linha |
| 11 | `fix4_ancora_dobrada` | patch funciona com a âncora partida |
| 12 | `fix4_preserva_fim_de_linha` | CRLF preservado; nenhum `\r\r\n`; manifesto válido pelo parser estrito |
| 13 | `fix4_pula_com_rhino` | nada baixado, jar byte a byte idêntico |
| 13 | `fix4_pula_com_nashorn_presente` | idem, quando o fix já foi aplicado |
| 14 | `fix4_ancora_ausente` | falha controlada: jar intacto, saída 1 |
| 15 | `fix4_sem_bundle_eclipse` | ausência do bundle não é erro |
| 16 | `fix5_limpa_cache_osgi` | cache removido; 2ª vez reporta `inalterado` |
| 17 | `offline_sem_cache_nao_corrompe` | download indisponível não corrompe o plugin |
| 18 | `cenario_2009_completo` | plugin recente (2.0.x): nada a baixar, nada a tocar |
| 19 | `cenario_1713_completo` | perfil do plugin antigo: Fix 3 + Fix 4 juntos |
| 20 | `caminho_com_espacos_e_acentos` | `Eclipse IDE 2026-03 (cópia) — teste.app` |
| 21 | `selecao_por_nome` | resolve o Eclipse pelo nome, como no uso interativo |
| 22 | `eclipse_inexistente` | saída 2 com mensagem clara |
| 23 | `plugin_fluig_ausente` | saída 2 dizendo qual plugin falta |
| 24 | `help_e_versao` | `--help`, `--version`, argumento inválido |

Total atual: **25 casos, 128 asserções.**

## Teste de mutação

Um teste que passa contra um script quebrado não vale nada. A suíte foi validada
revertendo cada correção e conferindo quais casos quebram:

| Mutação aplicada ao script | Casos que falharam |
|---|---|
| remover `--add-opens=java.base/java.lang` | 1, 2, 3, 4, 20 |
| procurar a âncora no manifesto cru (sem desdobrar) | 11, 19 |
| voltar a ler o `rt.jar` por pipe (`unzip -p /dev/stdin`) | 8, 9, 18 |
| remover a detecção de Rhino | 12, 18 |
| sobrescrever o `eclipse.ini.bak` a cada execução | 2 |
| não normalizar CRLF antes de redobrar o manifesto | 10, 11, 12 |

Para repetir: copie o script, aplique a mutação e rode
`FLUIG_FIX_SCRIPT=/caminho/mutante.command ./tests/run-tests.sh`.

**Ao adicionar um caso novo, faça esse exercício:** quebre de propósito o que ele
deveria proteger e confirme que ele reprova.

## O que a suíte NÃO cobre

Tudo que exige um Eclipse de verdade rodando:

- se o Equinox realmente carrega o `Bundle-ClassPath` remendado;
- qual `ScriptEngine` o plugin resolve em runtime (Nashorn vs. Rhino);
- se a exportação de workflow funciona de ponta a ponta;
- o crash nativo SWT/Cocoa.

Isso continua sendo verificação manual — veja a **Matriz de homologação** no
README principal.
