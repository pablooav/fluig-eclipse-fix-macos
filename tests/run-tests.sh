#!/bin/bash
# =============================================================================
# Suíte de testes do fluig-eclipse-fix.command
#
#   ./tests/run-tests.sh            roda tudo
#   ./tests/run-tests.sh fix4       roda só os casos cujo nome casa com "fix4"
#   KEEP_FIXTURES=1 ./tests/run-tests.sh    preserva o sandbox para inspeção
#
# Não acessa a rede (o script roda com --offline sobre um cache falso) e não
# toca em /Applications: tudo acontece dentro de um diretório temporário.
# =============================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${FLUIG_FIX_SCRIPT:-$ROOT/fluig-eclipse-fix.command}"

# shellcheck source=tests/lib/assert.sh
. "$ROOT/tests/lib/assert.sh"
# shellcheck source=tests/lib/fixtures.sh
. "$ROOT/tests/lib/fixtures.sh"

[ -x "$SCRIPT" ] || { echo "Script não encontrado ou sem permissão de execução: $SCRIPT"; exit 2; }
for dep in zip unzip python3; do
    command -v "$dep" >/dev/null 2>&1 || { echo "Dependência ausente: $dep"; exit 2; }
done

FILTER="${1:-}"

SESSION=$(mktemp -d "${TMPDIR:-/tmp}/fluig-fix-tests.XXXXXX")
CACHE="$SESSION/cache"
EMPTY_CACHE="$SESSION/cache-vazio"
mkdir -p "$EMPTY_CACHE"
fixture_cache "$CACHE"

cleanup() {
    if [ "${KEEP_FIXTURES:-0}" = "1" ]; then
        echo ""
        echo "Fixtures preservados em: $SESSION"
    else
        rm -rf "$SESSION"
    fi
}
trap cleanup EXIT

echo "Script sob teste: $SCRIPT ($("$SCRIPT" --version))"
echo "Sandbox:          $SESSION"

# -----------------------------------------------------------------------------
# Execução do script sob teste
# -----------------------------------------------------------------------------
RUN_CACHE=""
LAST_OUT=""
LAST_RC=0
REPORT=""

sandbox() { mktemp -d "$SESSION/caso.XXXXXX"; }

run_fix() { # run_fix <app> [args extras...]
    local app="$1"; shift
    REPORT="$(dirname "$app")/report.txt"
    rm -f "$REPORT"
    LAST_OUT=$("$SCRIPT" \
        --non-interactive \
        --offline \
        --eclipse "$app" \
        --search-dirs "$SESSION" \
        --cache-dir "${RUN_CACHE:-$CACHE}" \
        --report "$REPORT" \
        "$@" 2>&1)
    LAST_RC=$?
    RUN_CACHE=""
}

rep() { grep "^$1=" "$REPORT" 2>/dev/null | head -1 | cut -d= -f2-; }

# -----------------------------------------------------------------------------
# Inspeção de jars
# -----------------------------------------------------------------------------
manifest_unfolded() { # <jar>
    unzip -p "$1" META-INF/MANIFEST.MF 2>/dev/null | python3 -c \
        "import sys,re; sys.stdout.write(re.sub(r'\r?\n ','',sys.stdin.read()))"
}

max_manifest_line() { # <jar> → maior linha física em bytes
    unzip -p "$1" META-INF/MANIFEST.MF 2>/dev/null | python3 -c "
import sys
data = sys.stdin.buffer.read()
sep = b'\r\n' if b'\r\n' in data else b'\n'
print(max((len(l) for l in data.split(sep)), default=0))
"
}

rt_version_in() { # <plugin jar> → 'JAX-WS RI x.y.z'
    local probe; probe=$(mktemp)
    unzip -p "$1" META-INF/lib/rt.jar > "$probe" 2>/dev/null
    unzip -p "$probe" META-INF/MANIFEST.MF 2>/dev/null \
        | grep "Build-Version" | awk '{print $2, $3, $4}' | tr -d '\r'
    rm -f "$probe"
}

jar_has() { # <jar> <caminho interno>
    unzip -l "$1" 2>/dev/null | grep -qF " $2"
}

model_jar()   { find "$1/Contents/Eclipse/plugins" -maxdepth 1 -name 'com.totvs.tds.ecm.designer.model_*.jar' | head -1; }
eclipse_jar() { find "$1/Contents/Eclipse/plugins" -maxdepth 1 -name 'com.totvs.tds.ecm.designer.eclipse_*.jar' | head -1; }

should_run() { [ -z "$FILTER" ] || case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac; }

# =============================================================================
# Casos
# =============================================================================

caso_fix1_instalacao_limpa() {
    local t app ini
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Teste 2026-03" completo)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    ini="$app/Contents/Eclipse/eclipse.ini"
    cp "$ini" "$t/ini-original"

    run_fix "$app"

    assert_eq "sai com 0" "$LAST_RC" "0"
    assert_eq "fix1 reportado como aplicado" "$(rep fix1)" "aplicado"
    local f
    for f in "--add-opens=java.base/java.util=ALL-UNNAMED" \
             "--add-opens=java.base/java.lang=ALL-UNNAMED" \
             "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED" \
             "--add-opens=java.base/java.text=ALL-UNNAMED" \
             "--add-opens=java.desktop/java.awt.font=ALL-UNNAMED"; do
        assert_count "flag presente 1x: ${f#--add-opens=}" "$ini" "$f" "1"
    done
    assert_file_contains "java.lang (regressão: faltava e quebrava o export)" \
        "$ini" "--add-opens=java.base/java.lang=ALL-UNNAMED"
    assert_eq "flags entram logo após --add-modules=ALL-SYSTEM" \
        "$(grep -A1 -- '--add-modules=ALL-SYSTEM' "$ini" | tail -1)" \
        "--add-opens=java.desktop/java.awt.font=ALL-UNNAMED"
    assert_file_exists "backup do eclipse.ini criado" "${ini}.bak"
    assert_same_file "backup preserva o original" "${ini}.bak" "$t/ini-original"
}

caso_fix1_idempotente() {
    local t app ini
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Idem" completo)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    ini="$app/Contents/Eclipse/eclipse.ini"
    cp "$ini" "$t/ini-original"

    run_fix "$app"
    cp "$ini" "$t/ini-pos-1a"
    run_fix "$app"

    assert_eq "2ª execução sai com 0" "$LAST_RC" "0"
    assert_eq "2ª execução reporta inalterado" "$(rep fix1)" "inalterado"
    assert_same_file "eclipse.ini estável entre execuções" "$ini" "$t/ini-pos-1a"
    assert_count "sem duplicar java.lang" "$ini" "--add-opens=java.base/java.lang=ALL-UNNAMED" "1"
    assert_same_file "backup continua sendo o original (não é sobrescrito)" \
        "${ini}.bak" "$t/ini-original"
}

caso_fix1_sem_add_modules() {
    local t app ini
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Sem Modules" sem-modules)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    ini="$app/Contents/Eclipse/eclipse.ini"

    run_fix "$app"

    assert_eq "sai com 0" "$LAST_RC" "0"
    assert_count "java.lang adicionado no fim" "$ini" "--add-opens=java.base/java.lang=ALL-UNNAMED" "1"
    assert_count "todas as 5 flags" "$ini" "--add-opens=" "5"
    assert_eq "arquivo termina com quebra de linha" \
        "$(tail -c1 "$ini" | od -An -c | tr -d ' ')" '\n'
}

caso_fix1_colapsa_duplicatas() {
    local t app ini
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Duplicado" duplicado)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    ini="$app/Contents/Eclipse/eclipse.ini"

    run_fix "$app"

    assert_count "java.util colapsado para 1" "$ini" "--add-opens=java.base/java.util=ALL-UNNAMED" "1"
    assert_count "java.text (3x no fixture) colapsado para 1" "$ini" "--add-opens=java.base/java.text=ALL-UNNAMED" "1"
    assert_count "total de 5 add-opens" "$ini" "--add-opens=" "5"
    assert_count "SWT repetido 3x colapsado para 1" "$ini" \
        "-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed" "1"
}

caso_fix2_true_vira_false() {
    local t app ini
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse SWT True" swt-true)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    ini="$app/Contents/Eclipse/eclipse.ini"

    run_fix "$app"

    assert_eq "fix2 aplicado" "$(rep fix2)" "aplicado"
    assert_file_not_contains "não sobra =true" "$ini" \
        "-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=true"
    assert_count "exatamente um =false" "$ini" \
        "-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=false" "1"
}

caso_fix2_flag_ausente() {
    local t app ini
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse SWT Ausente" swt-ausente)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    ini="$app/Contents/Eclipse/eclipse.ini"

    run_fix "$app"

    assert_eq "fix2 aplicado" "$(rep fix2)" "aplicado"
    assert_count "flag adicionada uma vez" "$ini" \
        "-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=false" "1"
}

caso_fix2_ja_false() {
    local t app ini
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse SWT False" completo)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    ini="$app/Contents/Eclipse/eclipse.ini"

    run_fix "$app"

    assert_eq "fix2 inalterado" "$(rep fix2)" "inalterado"
    assert_count "continua com uma ocorrência" "$ini" \
        "-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=false" "1"
}

caso_fix3_patch_rt_jar() {
    local t app jar
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse RT 231" completo)
    fixture_model_plugin  "$app" 1.7.1.3 2.3.1
    fixture_eclipse_plugin "$app" 1.7.1.3 rhino
    jar=$(model_jar "$app")

    run_fix "$app"

    assert_eq "sai com 0" "$LAST_RC" "0"
    assert_eq "detectou a versão antiga" "$(rep rt_versao_antes)" "JAX-WS RI 2.3.1"
    assert_eq "fix3 aplicado" "$(rep fix3)" "aplicado"
    assert_eq "rt.jar agora é 2.3.5" "$(rt_version_in "$jar")" "JAX-WS RI 2.3.5"
    assert_file_exists "backup do plugin criado" "${jar}.bak"
    assert_eq "backup preserva o 2.3.1" "$(rt_version_in "${jar}.bak")" "JAX-WS RI 2.3.1"
    if unzip -t "$jar" >/dev/null 2>&1; then _pass "jar continua válido"; else _fail "jar continua válido"; fi
    if jar_has "$jar" "com/totvs/marcador.txt"; then _pass "conteúdo original preservado"; else _fail "conteúdo original preservado"; fi
    if jar_has "$jar" "META-INF/lib/xstream.jar"; then _pass "demais libs preservadas"; else _fail "demais libs preservadas"; fi
}

caso_fix3_ja_atualizado_nao_reaplica() {
    # Regressão: a detecção lia o rt.jar por pipe (`unzip -p /dev/stdin`), que
    # falha em silêncio porque o unzip precisa de seek. O resultado era
    # reaplicar o patch toda vez e nunca reportar "já atualizado".
    local t app jar
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse RT 235" completo)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    jar=$(model_jar "$app")
    cp "$jar" "$t/model-antes.jar"

    run_fix "$app"

    assert_eq "sai com 0" "$LAST_RC" "0"
    assert_eq "detecta 2.3.5 já presente" "$(rep rt_versao_antes)" "JAX-WS RI 2.3.5"
    assert_eq "fix3 reportado como já-atualizado" "$(rep fix3)" "ja-atualizado"
    assert_same_file "jar não foi tocado" "$jar" "$t/model-antes.jar"
    if [ -f "${jar}.bak" ]; then _fail "não cria backup desnecessário"; else _pass "não cria backup desnecessário"; fi
}

caso_fix4_aplica_sem_motor_js() {
    local t app jar cp
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Sem JS" completo)
    fixture_model_plugin  "$app" 1.7.1.3 2.3.5
    fixture_eclipse_plugin "$app" 1.7.1.3 plain
    jar=$(eclipse_jar "$app")

    run_fix "$app"

    assert_eq "sai com 0" "$LAST_RC" "0"
    assert_eq "fix4 aplicado" "$(rep fix4)" "aplicado"
    local lib
    for lib in nashorn-core.jar asm.jar asm-commons.jar asm-tree.jar asm-util.jar; do
        if jar_has "$jar" "META-INF/lib/$lib"; then _pass "lib embarcada: $lib"; else _fail "lib embarcada: $lib"; fi
    done
    cp=$(manifest_unfolded "$jar")
    for lib in nashorn-core.jar asm.jar asm-commons.jar asm-tree.jar asm-util.jar; do
        assert_contains "Bundle-ClassPath cita $lib" "$cp" "META-INF/lib/$lib"
    done
    assert_contains "âncora jaxws-api.jar preservada" "$cp" "META-INF/lib/jaxws-api.jar"
    local maxlen; maxlen=$(max_manifest_line "$jar")
    if [ "$maxlen" -le 72 ]; then _pass "manifesto respeita o limite de 72 bytes ($maxlen)"
    else _fail "manifesto respeita o limite de 72 bytes" "maior linha: $maxlen"; fi
    assert_file_exists "backup .bak.nashorn criado" "${jar}.bak.nashorn"
    assert_not_contains "backup é anterior ao patch" "$(manifest_unfolded "${jar}.bak.nashorn")" "nashorn-core.jar"
}

caso_fix4_ancora_dobrada() {
    # Regressão: a âncora 'META-INF/lib/jaxws-api.jar' pode estar partida por
    # uma continuação de 72 bytes. Sem desdobrar o manifesto antes, o patch
    # abortava em manifestos reais (foi o caso do 2.0.0.9).
    local t app jar cp
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Dobrado" completo)
    fixture_model_plugin  "$app" 1.7.1.3 2.3.5
    fixture_eclipse_plugin "$app" 1.7.1.3 folded
    jar=$(eclipse_jar "$app")

    # Confirma que o fixture de fato parte a âncora (senão o teste não prova nada)
    if unzip -p "$jar" META-INF/MANIFEST.MF | grep -qF "META-INF/lib/jaxws-api.jar"; then
        _fail "fixture tem a âncora partida por uma dobra" "a âncora apareceu contígua no manifesto cru"
    else
        _pass "fixture tem a âncora partida por uma dobra"
    fi

    run_fix "$app"

    assert_eq "sai com 0" "$LAST_RC" "0"
    assert_eq "fix4 aplicado mesmo com a âncora dobrada" "$(rep fix4)" "aplicado"
    cp=$(manifest_unfolded "$jar")
    assert_contains "nashorn no Bundle-ClassPath" "$cp" "META-INF/lib/nashorn-core.jar"
    assert_contains "asm-commons no Bundle-ClassPath" "$cp" "META-INF/lib/asm-commons.jar"
    assert_contains "entradas de preenchimento preservadas" "$cp" "META-INF/lib/pad00.jar"
    assert_contains "âncora preservada" "$cp" "META-INF/lib/jaxws-api.jar"
    local maxlen; maxlen=$(max_manifest_line "$jar")
    if [ "$maxlen" -le 72 ]; then _pass "redobra respeita 72 bytes ($maxlen)"
    else _fail "redobra respeita 72 bytes" "maior linha: $maxlen"; fi
}

caso_fix4_pula_com_rhino() {
    local t app jar
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Rhino" completo)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    jar=$(eclipse_jar "$app")
    cp "$jar" "$t/eclipse-antes.jar"

    run_fix "$app"

    assert_eq "sai com 0" "$LAST_RC" "0"
    assert_eq "fix4 pulado por motor próprio" "$(rep fix4)" "pulado-rhino"
    assert_contains "motor detectado é reportado" "$(rep fix4_motor)" "fluig-rhino.jar"
    assert_same_file "jar não foi tocado" "$jar" "$t/eclipse-antes.jar"
    if [ -f "${jar}.bak.nashorn" ]; then _fail "não cria backup desnecessário"; else _pass "não cria backup desnecessário"; fi
    assert_not_contains "nada foi baixado" "$LAST_OUT" "Baixando"
}

caso_fix4_pula_com_nashorn_presente() {
    local t app jar
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Nashorn" completo)
    fixture_model_plugin  "$app" 1.7.1.3 2.3.5
    fixture_eclipse_plugin "$app" 1.7.1.3 nashorn
    jar=$(eclipse_jar "$app")
    cp "$jar" "$t/eclipse-antes.jar"

    run_fix "$app"

    assert_eq "fix4 pulado (nashorn já presente)" "$(rep fix4)" "pulado-nashorn"
    assert_same_file "jar não foi tocado" "$jar" "$t/eclipse-antes.jar"
}

caso_fix4_ancora_ausente() {
    local t app jar
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Sem Ancora" completo)
    fixture_model_plugin  "$app" 1.7.1.3 2.3.5
    fixture_eclipse_plugin "$app" 1.7.1.3 no-anchor
    jar=$(eclipse_jar "$app")
    cp "$jar" "$t/eclipse-antes.jar"

    run_fix "$app"

    assert_eq "sinaliza falha no código de saída" "$LAST_RC" "1"
    assert_eq "fix4 marcado como falha de âncora" "$(rep fix4)" "falhou-ancora"
    assert_same_file "jar original preservado (não corrompe)" "$jar" "$t/eclipse-antes.jar"
    assert_contains "mensagem explica o motivo" "$LAST_OUT" "Bundle-ClassPath"
}

caso_fix4_sem_bundle_eclipse() {
    local t app
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse So Model" completo)
    fixture_model_plugin "$app" 2.0.0.9 2.3.5

    run_fix "$app"

    assert_eq "sai com 0 (ausência do bundle não é erro)" "$LAST_RC" "0"
    assert_eq "fix4 pulado por falta do bundle" "$(rep fix4)" "pulado-sem-bundle"
}

caso_fix5_limpa_cache_osgi() {
    local t app cache
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Cache" completo)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    cache="$app/Contents/Eclipse/configuration/org.eclipse.osgi"

    assert_dir_exists "cache existe antes" "$cache"
    run_fix "$app"
    assert_eq "fix5 aplicado" "$(rep fix5)" "aplicado"
    assert_dir_absent "cache removido" "$cache"

    run_fix "$app"
    assert_eq "2ª execução reporta inalterado" "$(rep fix5)" "inalterado"
}

caso_offline_sem_cache_nao_corrompe() {
    local t app jar
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Offline" completo)
    fixture_model_plugin  "$app" 1.7.1.3 2.3.1
    fixture_eclipse_plugin "$app" 1.7.1.3 rhino
    jar=$(model_jar "$app")
    cp "$jar" "$t/model-antes.jar"

    RUN_CACHE="$EMPTY_CACHE"
    run_fix "$app"

    assert_eq "sinaliza falha no código de saída" "$LAST_RC" "1"
    assert_eq "fix3 marcado como falha de download" "$(rep fix3)" "falhou-download"
    assert_same_file "plugin preservado intacto" "$jar" "$t/model-antes.jar"
    assert_eq "fix1 ainda foi aplicado" "$(rep fix1)" "aplicado"
    assert_eq "fix5 ainda foi aplicado" "$(rep fix5)" "aplicado"
    assert_contains "resumo avisa das pendências" "$LAST_OUT" "pendências"
}

caso_cenario_2009_completo() {
    # Perfil real do Eclipse M1 200 com plugin 2.0.0.9 após rodar o fix:
    # nada para baixar, só eclipse.ini e cache OSGi.
    local t app mjar ejar
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse M1 200" completo)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    mjar=$(model_jar "$app"); ejar=$(eclipse_jar "$app")
    cp "$mjar" "$t/model-antes.jar"; cp "$ejar" "$t/eclipse-antes.jar"

    RUN_CACHE="$EMPTY_CACHE"
    run_fix "$app"

    assert_eq "sai com 0 mesmo com cache vazio" "$LAST_RC" "0"
    assert_eq "fix3 já atualizado" "$(rep fix3)" "ja-atualizado"
    assert_eq "fix4 pulado (rhino)" "$(rep fix4)" "pulado-rhino"
    assert_same_file "model intacto" "$mjar" "$t/model-antes.jar"
    assert_same_file "eclipse intacto" "$ejar" "$t/eclipse-antes.jar"
    assert_not_contains "nenhum download" "$LAST_OUT" "Baixando"
}

caso_cenario_1713_completo() {
    # Perfil do plugin antigo: precisa das duas correções pesadas.
    local t app mjar ejar
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse M1 171" completo)
    fixture_model_plugin  "$app" 1.7.1.3 2.3.1
    fixture_eclipse_plugin "$app" 1.7.1.3 folded
    mjar=$(model_jar "$app"); ejar=$(eclipse_jar "$app")

    run_fix "$app"

    assert_eq "sai com 0" "$LAST_RC" "0"
    assert_eq "plugin detectado" "$(rep plugin_versao)" "1.7.1.3"
    assert_eq "fix3 aplicado" "$(rep fix3)" "aplicado"
    assert_eq "fix4 aplicado" "$(rep fix4)" "aplicado"
    assert_eq "rt.jar atualizado" "$(rt_version_in "$mjar")" "JAX-WS RI 2.3.5"
    assert_contains "nashorn no classpath" "$(manifest_unfolded "$ejar")" "nashorn-core.jar"
}

caso_caminho_com_espacos_e_acentos() {
    local t app ini
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse M1 200 (cópia) — teste" completo)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.1
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
    ini="$app/Contents/Eclipse/eclipse.ini"

    run_fix "$app"

    assert_eq "sai com 0" "$LAST_RC" "0"
    assert_eq "fix3 aplicado no caminho com espaços" "$(rep fix3)" "aplicado"
    assert_file_contains "eclipse.ini corrigido" "$ini" "--add-opens=java.base/java.lang=ALL-UNNAMED"
    assert_eq "rt.jar atualizado" "$(rt_version_in "$(model_jar "$app")")" "JAX-WS RI 2.3.5"
}

caso_selecao_por_nome() {
    # Sem --eclipse com caminho: o script tem que achar pelo nome dentro de
    # --search-dirs, como faz no uso interativo em /Applications.
    local t app
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Por Nome" completo)
    fixture_model_plugin  "$app" 2.0.0.9 2.3.5
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino

    REPORT="$t/report.txt"; rm -f "$REPORT"
    LAST_OUT=$("$SCRIPT" --non-interactive --offline \
        --eclipse "Eclipse Por Nome" \
        --search-dirs "$t" \
        --cache-dir "$CACHE" \
        --report "$REPORT" 2>&1)
    LAST_RC=$?

    assert_eq "resolve pelo nome" "$LAST_RC" "0"
    assert_eq "eclipse correto no relatório" "$(rep eclipse)" "$app"
}

caso_eclipse_inexistente() {
    local t
    t=$(sandbox)
    REPORT="$t/report.txt"; rm -f "$REPORT"
    LAST_OUT=$("$SCRIPT" --non-interactive --offline \
        --eclipse "$t/Nao Existe.app" --search-dirs "$t" \
        --cache-dir "$CACHE" --report "$REPORT" 2>&1)
    LAST_RC=$?

    assert_eq "sai com 2 (erro de uso)" "$LAST_RC" "2"
    assert_contains "mensagem clara" "$LAST_OUT" "Eclipse não encontrado"
}

caso_plugin_fluig_ausente() {
    local t app
    t=$(sandbox); app=$(fixture_eclipse "$t" "Eclipse Pelado" completo)

    run_fix "$app"

    assert_eq "sai com 2" "$LAST_RC" "2"
    assert_contains "diz qual plugin falta" "$LAST_OUT" "ecm.designer.model"
}

caso_help_e_versao() {
    local out rc
    out=$("$SCRIPT" --help 2>&1); rc=$?
    assert_eq "--help sai com 0" "$rc" "0"
    assert_contains "--help documenta --non-interactive" "$out" "--non-interactive"
    assert_contains "--help documenta --offline" "$out" "--offline"
    out=$("$SCRIPT" --version 2>&1); rc=$?
    assert_eq "--version sai com 0" "$rc" "0"
    assert_contains "--version imprime algo versionado" "$out" "."
    out=$("$SCRIPT" --parametro-invalido 2>&1); rc=$?
    assert_eq "argumento inválido sai com 2" "$rc" "2"
}

# =============================================================================
# Execução
# =============================================================================
CASES=(
    caso_fix1_instalacao_limpa
    caso_fix1_idempotente
    caso_fix1_sem_add_modules
    caso_fix1_colapsa_duplicatas
    caso_fix2_true_vira_false
    caso_fix2_flag_ausente
    caso_fix2_ja_false
    caso_fix3_patch_rt_jar
    caso_fix3_ja_atualizado_nao_reaplica
    caso_fix4_aplica_sem_motor_js
    caso_fix4_ancora_dobrada
    caso_fix4_pula_com_rhino
    caso_fix4_pula_com_nashorn_presente
    caso_fix4_ancora_ausente
    caso_fix4_sem_bundle_eclipse
    caso_fix5_limpa_cache_osgi
    caso_offline_sem_cache_nao_corrompe
    caso_cenario_2009_completo
    caso_cenario_1713_completo
    caso_caminho_com_espacos_e_acentos
    caso_selecao_por_nome
    caso_eclipse_inexistente
    caso_plugin_fluig_ausente
    caso_help_e_versao
)

for c in "${CASES[@]}"; do
    should_run "$c" || continue
    begin_case "${c#caso_}"
    "$c"
    end_case
done

if [ "$CASES_RUN" -eq 0 ]; then
    echo "Nenhum caso casou com o filtro '$FILTER'."
    exit 2
fi

summary
