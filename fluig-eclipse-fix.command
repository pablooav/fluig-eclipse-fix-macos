#!/bin/bash

# =============================================================================
# Fluig Plugin Fix
# Compatibilidade do plugin TOTVS Fluig Studio com Eclipse nativo em
# Apple Silicon (JRE JustJ / Java 21).
#
# Correções aplicadas:
#   1. eclipse.ini  → adiciona flags --add-opens (sem duplicatas)
#   2. eclipse.ini  → desativa rastreamento estrito de recursos SWT
#   3. rt.jar patch → substitui JAX-WS RI 2.3.1 pelo 2.3.5 no plugin Fluig
#   4. nashorn-core → adiciona Nashorn ao Bundle-ClassPath (só quando o plugin
#                     não embarca motor JS próprio)
#   5. OSGi cache   → limpa cache para forçar releitura dos plugins
#
# Uso interativo (duplo clique no Finder):
#   ./fluig-eclipse-fix.command
#
# Uso automatizado (CI / suíte de testes):
#   ./fluig-eclipse-fix.command --non-interactive --eclipse "/caminho/Ecl.app" \
#       --offline --cache-dir ./cache --report ./report.txt
#
# Variáveis de ambiente equivalentes às flags:
#   FLUIG_FIX_ECLIPSE, FLUIG_FIX_NON_INTERACTIVE, FLUIG_FIX_OFFLINE,
#   FLUIG_FIX_CACHE_DIR, FLUIG_FIX_REPORT, FLUIG_FIX_SEARCH_DIRS
# =============================================================================

FIX_VERSION="1.0.0"

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $1"; }
log_section() { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE} $1${NC}"; echo -e "${BLUE}========================================${NC}"; }

# =============================================================================
# Configuração: variáveis de ambiente + flags de linha de comando
# =============================================================================
NON_INTERACTIVE="${FLUIG_FIX_NON_INTERACTIVE:-false}"
ECLIPSE_TARGET="${FLUIG_FIX_ECLIPSE:-}"
OFFLINE="${FLUIG_FIX_OFFLINE:-false}"
CACHE_DIR="${FLUIG_FIX_CACHE_DIR:-${TMPDIR:-/tmp}}"
REPORT_FILE="${FLUIG_FIX_REPORT:-}"
SEARCH_DIRS_RAW="${FLUIG_FIX_SEARCH_DIRS:-/Applications/Eclipses:/Applications}"

usage() {
    cat <<EOF
Fluig Plugin Fix v${FIX_VERSION}

  --eclipse <nome|caminho>  Eclipse alvo (nome sem .app ou caminho do bundle)
  --non-interactive, -y     Não pergunta nada e não espera Enter no final
  --offline                 Não acessa a rede; usa apenas o cache local
  --cache-dir <dir>         Onde guardar/procurar os artefatos baixados
                            (padrão: \$TMPDIR)
  --search-dirs <a:b:c>     Diretórios onde procurar Eclipse
                            (padrão: /Applications/Eclipses:/Applications)
  --report <arquivo>        Grava um relatório chave=valor do que foi aplicado
  --version                 Mostra a versão e sai
  --help, -h                Esta ajuda

Códigos de saída: 0 = tudo certo · 1 = alguma correção falhou
                  2 = erro de uso / pré-requisito ausente
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --eclipse)          ECLIPSE_TARGET="$2"; shift 2 ;;
        --eclipse=*)        ECLIPSE_TARGET="${1#*=}"; shift ;;
        --non-interactive|-y) NON_INTERACTIVE=true; shift ;;
        --offline)          OFFLINE=true; shift ;;
        --cache-dir)        CACHE_DIR="$2"; shift 2 ;;
        --cache-dir=*)      CACHE_DIR="${1#*=}"; shift ;;
        --search-dirs)      SEARCH_DIRS_RAW="$2"; shift 2 ;;
        --search-dirs=*)    SEARCH_DIRS_RAW="${1#*=}"; shift ;;
        --report)           REPORT_FILE="$2"; shift 2 ;;
        --report=*)         REPORT_FILE="${1#*=}"; shift ;;
        --version)          echo "$FIX_VERSION"; exit 0 ;;
        --help|-h)          usage; exit 0 ;;
        *)                  echo "Argumento desconhecido: $1"; usage; exit 2 ;;
    esac
done

IFS=':' read -r -a SEARCH_DIRS <<< "$SEARCH_DIRS_RAW"

# =============================================================================
# Relatório legível por máquina (usado pela suíte de testes)
# =============================================================================
REPORT_LINES=()
EXIT_CODE=0

report() { REPORT_LINES+=("$1=$2"); }

flush_report() {
    [ -n "$REPORT_FILE" ] || return 0
    [ ${#REPORT_LINES[@]} -gt 0 ] || return 0
    printf '%s\n' "${REPORT_LINES[@]}" > "$REPORT_FILE"
}
trap flush_report EXIT

pause() {
    [ "$NON_INTERACTIVE" = true ] && return 0
    echo ""
    echo "Pressione Enter para fechar..."
    read -r < /dev/tty
    osascript -e 'tell application "Terminal" to close front window' 2>/dev/null &
    sleep 0.3
}

abort() {
    log_error "$1"
    report status "abortado"
    report erro "$1"
    pause
    exit "${2:-2}"
}

# Baixa um artefato, reaproveitando o cache. Respeita o modo offline.
fetch() {
    local url="$1" dest="$2" label="$3"
    if [ -f "$dest" ]; then
        log_info "$label já está no cache. Reutilizando."
        return 0
    fi
    if [ "$OFFLINE" = true ]; then
        log_error "Modo offline: $label não está no cache ($dest)."
        return 1
    fi
    log_info "Baixando $label..."
    mkdir -p "$(dirname "$dest")"
    if ! curl -fsSL "$url" -o "$dest"; then
        rm -f "$dest"
        log_error "Falha ao baixar $url"
        return 1
    fi
    log_ok "$label baixado ($(du -h "$dest" | cut -f1))"
    return 0
}

# =============================================================================
# Cabeçalho e seleção do Eclipse
# =============================================================================
if [ "$NON_INTERACTIVE" != true ]; then
    clear
    echo ""
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║       Fluig Plugin Fix                   ║"
    echo "  ║       Compatibilidade Java 21 / ARM      ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""
fi

ECLIPSE_LIST=()
for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r app; do
        [ -f "$app/Contents/Eclipse/eclipse.ini" ] || continue
        ECLIPSE_LIST+=("$(basename "$app" .app)|$app")
    done < <(find "$dir" -maxdepth 1 -name "*.app" 2>/dev/null | sort)
done

if [ "$NON_INTERACTIVE" != true ]; then
    echo "  Eclipse instalados:"
    echo ""
    for entry in "${ECLIPSE_LIST[@]}"; do
        echo "    → ${entry%%|*}"
    done
fi

if [ ${#ECLIPSE_LIST[@]} -eq 0 ] && [ -z "$ECLIPSE_TARGET" ]; then
    abort "Nenhum Eclipse encontrado em: ${SEARCH_DIRS_RAW}"
fi

if [ -z "$ECLIPSE_TARGET" ]; then
    echo ""
    echo -n "  Digite o nome exato do Eclipse (sem .app): "
    read -r ECLIPSE_TARGET < /dev/tty
fi

if [ -z "$ECLIPSE_TARGET" ]; then
    abort "Nenhum Eclipse informado."
fi

# Resolve: caminho do bundle, caminho sem .app, ou nome dentro de SEARCH_DIRS
ECLIPSE_APP=""
if [ -f "$ECLIPSE_TARGET/Contents/Eclipse/eclipse.ini" ]; then
    ECLIPSE_APP="$ECLIPSE_TARGET"
elif [ -f "${ECLIPSE_TARGET}.app/Contents/Eclipse/eclipse.ini" ]; then
    ECLIPSE_APP="${ECLIPSE_TARGET}.app"
else
    for entry in "${ECLIPSE_LIST[@]}"; do
        if [ "${entry%%|*}" = "$ECLIPSE_TARGET" ]; then
            ECLIPSE_APP="${entry##*|}"
            break
        fi
    done
fi

[ -n "$ECLIPSE_APP" ] || abort "Eclipse não encontrado: $ECLIPSE_TARGET"

ECLIPSE_NAME=$(basename "$ECLIPSE_APP" .app)

RT_URL="https://repo1.maven.org/maven2/com/sun/xml/ws/rt/2.3.5/rt-2.3.5.jar"
RT_LOCAL="$CACHE_DIR/jaxws-rt-2.3.5.jar"
NASHORN_URL="https://repo1.maven.org/maven2/org/openjdk/nashorn/nashorn-core/15.4/nashorn-core-15.4.jar"
NASHORN_LOCAL="$CACHE_DIR/nashorn-core-15.4.jar"
ASM_BASE="https://repo1.maven.org/maven2/org/ow2/asm"
ASM_LOCAL="$CACHE_DIR/fluig_asm"
WORKROOT="${TMPDIR:-/tmp}"
ECLIPSE_INI="$ECLIPSE_APP/Contents/Eclipse/eclipse.ini"
OSGI_CACHE="$ECLIPSE_APP/Contents/Eclipse/configuration/org.eclipse.osgi"
PLUGINS_DIR="$ECLIPSE_APP/Contents/Eclipse/plugins"

# Detecta automaticamente a versão do plugin Fluig instalada
PLUGIN_JAR=$(find "$PLUGINS_DIR" -maxdepth 1 -name 'com.totvs.tds.ecm.designer.model_*.jar' 2>/dev/null | sort -V | tail -1)
ECLIPSE_JAR=$(find "$PLUGINS_DIR" -maxdepth 1 -name 'com.totvs.tds.ecm.designer.eclipse_*.jar' 2>/dev/null | sort -V | tail -1)

report eclipse "$ECLIPSE_APP"
report versao_script "$FIX_VERSION"

# =============================================================================
# Verificações iniciais
# =============================================================================
log_section "Verificações"

log_ok "Eclipse encontrado: $ECLIPSE_NAME"
log_ok "eclipse.ini encontrado"

if [ -z "$PLUGIN_JAR" ]; then
    abort "Plugin Fluig (ecm.designer.model) não encontrado em $PLUGINS_DIR"
fi
PLUGIN_VERSION=$(basename "$PLUGIN_JAR" | sed 's/com.totvs.tds.ecm.designer.model_//' | sed 's/\.jar//')
log_ok "Plugin Fluig detectado: versão $PLUGIN_VERSION"
report plugin_versao "$PLUGIN_VERSION"

if [ -z "$ECLIPSE_JAR" ]; then
    log_warn "Plugin ecm.designer.eclipse não encontrado — Fix 4 será pulado."
fi

if [ "$OFFLINE" = true ]; then
    log_info "Modo offline: nenhum download será feito (cache: $CACHE_DIR)"
elif ! command -v curl &>/dev/null; then
    abort "curl não encontrado. Instale via: brew install curl"
else
    log_ok "curl disponível"
fi

if ! command -v unzip &>/dev/null || ! command -v zip &>/dev/null; then
    abort "unzip/zip não encontrados."
fi
log_ok "zip/unzip disponíveis"

if ! command -v python3 &>/dev/null; then
    abort "python3 não encontrado — é necessário para os Fixes 1 e 4. Instale com: xcode-select --install"
fi
log_ok "python3 disponível"

# =============================================================================
# FIX 1: eclipse.ini — flags --add-opens (sem duplicatas)
# =============================================================================
log_section "Fix 1: eclipse.ini (--add-opens Java 21)"

OPENS_NEEDED=(
    "--add-opens=java.base/java.util=ALL-UNNAMED"
    # java.lang e exigido pelo JAX-WS RI: com.sun.xml.ws.model.Injector reflete
    # sobre ClassLoader.defineClass/resolveClass/getPackage no seu init estatico.
    # Sem esta flag, a exportacao de processo falha com
    # "NoClassDefFoundError: Could not initialize class com.sun.xml.ws.model.Injector".
    "--add-opens=java.base/java.lang=ALL-UNNAMED"
    "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED"
    "--add-opens=java.base/java.text=ALL-UNNAMED"
    "--add-opens=java.desktop/java.awt.font=ALL-UNNAMED"
)

# Backup só na primeira execução: sobrescrever perderia o arquivo original.
if [ ! -f "${ECLIPSE_INI}.bak" ]; then
    cp "$ECLIPSE_INI" "${ECLIPSE_INI}.bak"
    log_info "Backup criado: eclipse.ini.bak"
else
    log_info "Backup já existe: eclipse.ini.bak (mantido)"
fi

INI_BEFORE="${WORKROOT}/fluig_ini_before_$$"
cp "$ECLIPSE_INI" "$INI_BEFORE"

# Remove duplicatas via python3 e adiciona as flags faltantes
python3 - "$ECLIPSE_INI" "${OPENS_NEEDED[@]}" << 'PYEOF'
import sys

ini_path = sys.argv[1]
opens_needed = sys.argv[2:]

with open(ini_path, 'r') as f:
    lines = f.readlines()

# Remove duplicatas de --add-opens
seen = set()
result = []
for line in lines:
    stripped = line.strip()
    if stripped.startswith('--add-opens='):
        if stripped in seen:
            continue
        seen.add(stripped)
    result.append(line)

# Garante que a ultima linha termine com \n antes de concatenar
content = ''.join(result)
if content and not content.endswith('\n'):
    content += '\n'

# Adiciona as que faltam, apos --add-modules=ALL-SYSTEM
for flag in opens_needed:
    if flag not in content:
        content = content.replace('--add-modules=ALL-SYSTEM\n',
                                  f'--add-modules=ALL-SYSTEM\n{flag}\n', 1)
        if flag not in content:
            content += f'{flag}\n'

with open(ini_path, 'w') as f:
    f.write(content)
PYEOF

if cmp -s "$INI_BEFORE" "$ECLIPSE_INI"; then
    log_warn "Nenhuma mudança necessária — flags já estavam corretas."
    report fix1 "inalterado"
else
    log_ok "Flags --add-opens verificadas/adicionadas (sem duplicatas)"
    report fix1 "aplicado"
fi
rm -f "$INI_BEFORE"

# =============================================================================
# FIX 2: eclipse.ini — desativa reportNonDisposed (crash SWT)
# =============================================================================
log_section "Fix 2: eclipse.ini (SWT reportNonDisposed)"

SWT_FLAG="-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed"

INI_BEFORE="${WORKROOT}/fluig_ini2_before_$$"
cp "$ECLIPSE_INI" "$INI_BEFORE"

# Normaliza para =false e remove ocorrencias repetidas (instalacoes antigas
# acumulam a mesma flag varias vezes no fim do arquivo).
python3 - "$ECLIPSE_INI" "$SWT_FLAG" << 'PYEOF'
import sys

ini_path, flag = sys.argv[1], sys.argv[2]

with open(ini_path, 'r') as f:
    lines = f.readlines()

out, seen = [], False
for line in lines:
    if line.strip().startswith(flag + '='):
        if seen:
            continue
        seen = True
        out.append(flag + '=false\n')
        continue
    out.append(line)

content = ''.join(out)
if content and not content.endswith('\n'):
    content += '\n'
if not seen:
    content += flag + '=false\n'

with open(ini_path, 'w') as f:
    f.write(content)
PYEOF

if cmp -s "$INI_BEFORE" "$ECLIPSE_INI"; then
    log_warn "reportNonDisposed já está como false. Pulando."
    report fix2 "inalterado"
else
    log_ok "reportNonDisposed=false garantido (duplicatas removidas)"
    report fix2 "aplicado"
fi
rm -f "$INI_BEFORE"

# =============================================================================
# FIX 3: rt.jar — JAX-WS RI 2.3.1 → 2.3.5
# =============================================================================
log_section "Fix 3: JAX-WS RI rt.jar (2.3.1 → 2.3.5)"

# O rt.jar precisa ser materializado em disco antes de ser lido: o unzip exige
# acesso aleatorio (seek) e falha silenciosamente com `unzip -p /dev/stdin`
# quando a entrada vem de um pipe. Ler direto do pipe fazia a deteccao retornar
# sempre vazio, e o Fix 3 reaplicava (e rebaixava) o patch a cada execucao.
CURRENT_VERSION=""
if [ -f "$PLUGIN_JAR" ]; then
    RT_PROBE="${WORKROOT}/fluig_rt_probe_$$.jar"
    if unzip -p "$PLUGIN_JAR" META-INF/lib/rt.jar > "$RT_PROBE" 2>/dev/null && [ -s "$RT_PROBE" ]; then
        CURRENT_VERSION=$(unzip -p "$RT_PROBE" META-INF/MANIFEST.MF 2>/dev/null | \
            grep "Build-Version" | awk '{print $2, $3, $4}' | tr -d '\r')
    fi
    rm -f "$RT_PROBE"
fi
report rt_versao_antes "${CURRENT_VERSION:-desconhecida}"

if [ "$CURRENT_VERSION" = "JAX-WS RI 2.3.5" ]; then
    log_warn "rt.jar já está na versão 2.3.5. Pulando."
    report fix3 "ja-atualizado"
elif ! fetch "$RT_URL" "$RT_LOCAL" "JAX-WS RI 2.3.5"; then
    log_error "Fix 3 não aplicado: rt.jar 2.3.5 indisponível."
    report fix3 "falhou-download"
    EXIT_CODE=1
else
    log_info "Versão atual do rt.jar: ${CURRENT_VERSION:-desconhecida}"

    VERSION_CHECK=$(unzip -p "$RT_LOCAL" META-INF/MANIFEST.MF 2>/dev/null | grep "Build-Version")
    if [[ "$VERSION_CHECK" != *"2.3.5"* ]]; then
        rm -f "$RT_LOCAL"
        abort "rt.jar baixado parece corrompido ou inválido." 1
    fi
    log_ok "rt.jar 2.3.5 verificado: $VERSION_CHECK"

    if [ ! -f "${PLUGIN_JAR}.bak" ]; then
        cp "$PLUGIN_JAR" "${PLUGIN_JAR}.bak"
        log_info "Backup criado: $(basename "$PLUGIN_JAR").bak"
    else
        log_warn "Backup já existe. Mantendo backup original."
    fi

    WORKDIR="${WORKROOT}/fluig_patch_$$"
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR/extracted"

    log_info "Extraindo plugin..."
    unzip -q "$PLUGIN_JAR" -d "$WORKDIR/extracted/"

    log_info "Substituindo rt.jar..."
    mkdir -p "$WORKDIR/extracted/META-INF/lib"
    cp "$RT_LOCAL" "$WORKDIR/extracted/META-INF/lib/rt.jar"

    log_info "Reempacotando plugin..."
    ( cd "$WORKDIR/extracted" && zip -qrX "$WORKDIR/patched.jar" . )

    if [ ! -f "$WORKDIR/patched.jar" ]; then
        rm -rf "$WORKDIR"
        log_error "Falha ao reempacotar o plugin. Fix 3 abortado (jar original preservado)."
        report fix3 "falhou-repack"
        EXIT_CODE=1
    else
        cp "$WORKDIR/patched.jar" "$PLUGIN_JAR"
        rm -rf "$WORKDIR"
        log_ok "Plugin atualizado com JAX-WS RI 2.3.5"
        report fix3 "aplicado"
    fi
fi

# =============================================================================
# FIX 4: nashorn-core — ScriptEngine "js" para Java 21
# =============================================================================
log_section "Fix 4: Nashorn standalone (Java 21 — ScriptEngine 'js')"

# O Nashorn foi removido do JDK no Java 15 (JEP 372). Mas a partir da 1.8.2.x a
# TOTVS passou a embarcar o Rhino como ScriptEngine no proprio plugin. Quando o
# plugin ja traz um motor JS, injetar Nashorn e desnecessario e ainda cria dois
# engines concorrentes registrados via ServiceLoader. Detectamos a capacidade em
# vez de comparar numero de versao -- e mais robusto entre builds da TOTVS.
RHINO_LIBS=""
if [ -n "$ECLIPSE_JAR" ]; then
    RHINO_LIBS=$(unzip -l "$ECLIPSE_JAR" 2>/dev/null | grep -oE "META-INF/lib/[^ ]*rhino[^ ]*\.jar" | sort -u | tr '\n' ' ')
fi

if [ -z "$ECLIPSE_JAR" ]; then
    log_warn "Plugin ecm.designer.eclipse não encontrado. Pulando Fix 4."
    report fix4 "pulado-sem-bundle"
elif unzip -l "$ECLIPSE_JAR" 2>/dev/null | grep -q "META-INF/lib/nashorn-core.jar"; then
    log_warn "nashorn-core já está no Bundle-ClassPath. Pulando Fix 4."
    report fix4 "pulado-nashorn"
elif [ -n "$RHINO_LIBS" ]; then
    log_warn "O plugin já embarca motor JS próprio: ${RHINO_LIBS}"
    log_warn "Nashorn é desnecessário nesta versão. Pulando Fix 4 (nada será baixado)."
    report fix4 "pulado-rhino"
    report fix4_motor "${RHINO_LIBS% }"
else
    DEPS_OK=true
    fetch "$NASHORN_URL" "$NASHORN_LOCAL" "nashorn-core 15.4" || DEPS_OK=false

    # Dependências de runtime do nashorn-core
    if [ "$DEPS_OK" = true ]; then
        mkdir -p "$ASM_LOCAL"
        for artifact in "asm/9.5/asm-9.5.jar:asm.jar" \
                        "asm-commons/9.5/asm-commons-9.5.jar:asm-commons.jar" \
                        "asm-tree/9.5/asm-tree-9.5.jar:asm-tree.jar" \
                        "asm-util/9.5/asm-util-9.5.jar:asm-util.jar"; do
            src="${artifact%%:*}"
            dest="$ASM_LOCAL/${artifact##*:}"
            if ! fetch "${ASM_BASE}/${src}" "$dest" "$(basename "$dest")"; then
                DEPS_OK=false
                break
            fi
        done
    fi

    if [ "$DEPS_OK" = false ]; then
        log_error "Dependências do Nashorn indisponíveis. Fix 4 não aplicado."
        report fix4 "falhou-download"
        EXIT_CODE=1
    else
        if [ ! -f "${ECLIPSE_JAR}.bak.nashorn" ]; then
            cp "$ECLIPSE_JAR" "${ECLIPSE_JAR}.bak.nashorn"
            log_info "Backup criado: $(basename "$ECLIPSE_JAR").bak.nashorn"
        else
            log_warn "Backup já existe. Mantendo backup original."
        fi

        WORKDIR_N="${WORKROOT}/fluig_nashorn_$$"
        rm -rf "$WORKDIR_N"
        mkdir -p "$WORKDIR_N/extracted"
        unzip -q "$ECLIPSE_JAR" -d "$WORKDIR_N/extracted"

        python3 - "$WORKDIR_N/extracted/META-INF/MANIFEST.MF" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r', newline='') as f:
    raw = f.read()

# A spec JAR limita linhas do manifesto a 72 bytes e continua com um espaco.
# A ancora pode cair em cima de uma dobra, entao desdobramos antes de procurar.
unfolded = re.sub(r'\r?\n ', '', raw)

old = 'META-INF/lib/jaxws-api.jar'
if old not in unfolded:
    print("ERRO: 'jaxws-api.jar' nao encontrado no Bundle-ClassPath.")
    sys.exit(1)

add = ',' + ','.join('META-INF/lib/' + j for j in
                     ['nashorn-core.jar', 'asm.jar', 'asm-commons.jar',
                      'asm-tree.jar', 'asm-util.jar'])
unfolded = unfolded.replace(old, old + add, 1)

# Redobra em 72 bytes: continuacoes comecam com um espaco.
out = []
for line in unfolded.split('\n'):
    b = line.encode('utf-8')
    if len(b) <= 72:
        out.append(line)
        continue
    out.append(b[:72].decode('utf-8', 'ignore'))
    rest = b[72:]
    while rest:
        out.append(' ' + rest[:71].decode('utf-8', 'ignore'))
        rest = rest[71:]

with open(path, 'w', newline='') as f:
    f.write('\r\n'.join(out) if '\r\n' in raw else '\n'.join(out))
PYEOF
        MANIFEST_STATUS=$?

        if [ $MANIFEST_STATUS -ne 0 ]; then
            rm -rf "$WORKDIR_N"
            log_error "Fix 4 abortado: não foi possível atualizar o Bundle-ClassPath."
            log_warn "O jar original foi preservado."
            report fix4 "falhou-ancora"
            EXIT_CODE=1
        else
            mkdir -p "$WORKDIR_N/extracted/META-INF/lib"
            cp "$NASHORN_LOCAL"             "$WORKDIR_N/extracted/META-INF/lib/nashorn-core.jar"
            cp "$ASM_LOCAL/asm.jar"         "$WORKDIR_N/extracted/META-INF/lib/"
            cp "$ASM_LOCAL/asm-commons.jar" "$WORKDIR_N/extracted/META-INF/lib/"
            cp "$ASM_LOCAL/asm-tree.jar"    "$WORKDIR_N/extracted/META-INF/lib/"
            cp "$ASM_LOCAL/asm-util.jar"    "$WORKDIR_N/extracted/META-INF/lib/"

            ( cd "$WORKDIR_N/extracted" && zip -qrX "$WORKDIR_N/patched.jar" . )

            if [ ! -f "$WORKDIR_N/patched.jar" ]; then
                rm -rf "$WORKDIR_N"
                log_error "Falha ao reempacotar o plugin (nashorn). Jar original preservado."
                report fix4 "falhou-repack"
                EXIT_CODE=1
            else
                cp "$WORKDIR_N/patched.jar" "$ECLIPSE_JAR"
                rm -rf "$WORKDIR_N"
                log_ok "nashorn-core adicionado ao Bundle-ClassPath (ScriptEngine 'js' disponível no Java 21)"
                report fix4 "aplicado"
            fi
        fi
    fi
fi

# =============================================================================
# FIX 5: Limpar cache OSGi
# =============================================================================
log_section "Fix 5: Limpeza do cache OSGi"

if [ -d "$OSGI_CACHE" ]; then
    rm -rf "$OSGI_CACHE"
    log_ok "Cache OSGi removido (será recriado na próxima inicialização)"
    report fix5 "aplicado"
else
    log_warn "Cache OSGi não encontrado (já estava limpo)"
    report fix5 "inalterado"
fi

# =============================================================================
# Resumo final
# =============================================================================
status_of() {
    local key="$1"
    for line in "${REPORT_LINES[@]}"; do
        [ "${line%%=*}" = "$key" ] && { echo "${line#*=}"; return 0; }
    done
    echo "?"
}

mark() {
    case "$1" in
        aplicado)      echo "✓" ;;
        inalterado|ja-atualizado|pulado-*) echo "–" ;;
        *)             echo "✗" ;;
    esac
}

echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        Correções concluídas              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
else
    echo -e "${YELLOW}╔══════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║     Concluído com pendências             ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════╝${NC}"
fi
echo ""
printf "  %s  eclipse.ini — flags --add-opens Java 21   [%s]\n" "$(mark "$(status_of fix1)")" "$(status_of fix1)"
printf "  %s  eclipse.ini — SWT reportNonDisposed=false [%s]\n" "$(mark "$(status_of fix2)")" "$(status_of fix2)"
printf "  %s  rt.jar      — JAX-WS RI 2.3.5             [%s]\n" "$(mark "$(status_of fix3)")" "$(status_of fix3)"
printf "  %s  nashorn     — Bundle-ClassPath            [%s]\n" "$(mark "$(status_of fix4)")" "$(status_of fix4)"
printf "  %s  OSGi cache  — limpeza                     [%s]\n" "$(mark "$(status_of fix5)")" "$(status_of fix5)"
echo ""
echo "  Legenda: ✓ aplicado agora · – nada a fazer · ✗ falhou"
echo ""
echo "  Eclipse:              $ECLIPSE_NAME"
echo "  Plugin Fluig versão:  $PLUGIN_VERSION"
echo ""
echo "  Backups criados:"
echo "    • eclipse.ini.bak"
[ -f "${PLUGIN_JAR}.bak" ]          && echo "    • $(basename "$PLUGIN_JAR").bak"
[ -f "${ECLIPSE_JAR}.bak.nashorn" ] && echo "    • $(basename "$ECLIPSE_JAR").bak.nashorn"
echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
    echo "  Abra o Eclipse normalmente."
    echo "  A primeira inicialização pode ser um pouco mais lenta."
else
    echo "  Alguma correção não pôde ser aplicada — veja os [ERRO] acima."
fi
echo ""

report status "concluido"
pause
exit "$EXIT_CODE"
