#!/bin/bash

# =============================================================================
# Fluig Plugin Fix (Java 21 / ARM)
# Aplica automaticamente as correções necessárias para o plugin funcionar.
#
# Correções aplicadas:
#   1. eclipse.ini  → adiciona flags --add-opens (sem duplicatas)
#   2. eclipse.ini  → desativa rastreamento estrito de recursos SWT
#   3. rt.jar patch → substitui JAX-WS RI 2.3.1 pelo 2.3.5 no plugin Fluig
#   4. nashorn-core → adiciona Nashorn standalone ao Bundle-ClassPath (Java 21)
#   5. OSGi cache   → limpa cache para forçar releitura dos plugins
# =============================================================================

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

pause() {
    echo ""
    echo "Pressione Enter para fechar..."
    read -r < /dev/tty
    osascript -e 'tell application "Terminal" to close front window' 2>/dev/null &
    sleep 0.3
}

abort() {
    log_error "$1"
    pause
    exit 1
}

# =============================================================================
# Cabeçalho e seleção do Eclipse
# =============================================================================
clear
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║       Fluig Plugin Fix                   ║"
echo "  ║       Compatibilidade Java 21 / ARM      ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# Lista os Eclipse disponíveis em /Applications/Eclipses e /Applications
SEARCH_DIRS=("/Applications/Eclipses" "/Applications")
echo "  Eclipse instalados:"
echo ""
ECLIPSE_LIST=()
for dir in "${SEARCH_DIRS[@]}"; do
    while IFS= read -r app; do
        name=$(basename "$app" .app)
        ECLIPSE_LIST+=("$name|$app")
        echo "    → $name  ($dir)"
    done < <(find "$dir" -maxdepth 1 -name "*.app" 2>/dev/null | xargs -I{} sh -c '[ -f "{}/Contents/Eclipse/eclipse.ini" ] && echo "{}"' 2>/dev/null | sort)
done

if [ ${#ECLIPSE_LIST[@]} -eq 0 ]; then
    abort "Nenhum Eclipse encontrado."
fi

echo ""
echo -n "  Digite o nome exato do Eclipse (sem .app): "
read -r ECLIPSE_NAME < /dev/tty

if [ -z "$ECLIPSE_NAME" ]; then
    abort "Nenhum nome informado."
fi

# Resolve o caminho completo
ECLIPSE_APP=""
for entry in "${ECLIPSE_LIST[@]}"; do
    name="${entry%%|*}"
    path="${entry##*|}"
    if [ "$name" = "$ECLIPSE_NAME" ]; then
        ECLIPSE_APP="$path"
        break
    fi
done
if [ -z "$ECLIPSE_APP" ]; then
    ECLIPSE_APP="/Applications/${ECLIPSE_NAME}.app"
fi

RT_URL="https://repo1.maven.org/maven2/com/sun/xml/ws/rt/2.3.5/rt-2.3.5.jar"
RT_LOCAL="/tmp/jaxws-rt-2.3.5.jar"
NASHORN_URL="https://repo1.maven.org/maven2/org/openjdk/nashorn/nashorn-core/15.4/nashorn-core-15.4.jar"
NASHORN_LOCAL="/tmp/nashorn-core-15.4.jar"
ASM_BASE="https://repo1.maven.org/maven2/org/ow2/asm"
ASM_LOCAL="/tmp/fluig_asm"
WORKDIR="/tmp/fluig_patch_$$"
ECLIPSE_INI="$ECLIPSE_APP/Contents/Eclipse/eclipse.ini"
OSGI_CACHE="$ECLIPSE_APP/Contents/Eclipse/configuration/org.eclipse.osgi"
PLUGINS_DIR="$ECLIPSE_APP/Contents/Eclipse/plugins"

# Detecta automaticamente a versão do plugin Fluig instalada
PLUGIN_JAR=$(ls "$PLUGINS_DIR/com.totvs.tds.ecm.designer.model_"*.jar 2>/dev/null | grep -v "\.bak" | sort -V | tail -1)
ECLIPSE_JAR=$(ls "$PLUGINS_DIR/com.totvs.tds.ecm.designer.eclipse_"*.jar 2>/dev/null | grep -v "\.bak" | sort -V | tail -1)

# =============================================================================
# Verificações iniciais
# =============================================================================
log_section "Verificações"

if [ ! -d "$ECLIPSE_APP" ]; then
    abort "Eclipse não encontrado em: $ECLIPSE_APP"
fi
log_ok "Eclipse encontrado: $ECLIPSE_NAME"

if [ ! -f "$ECLIPSE_INI" ]; then
    abort "eclipse.ini não encontrado em: $ECLIPSE_INI"
fi
log_ok "eclipse.ini encontrado"

if [ -z "$PLUGIN_JAR" ]; then
    abort "Plugin Fluig (ecm.designer.model) não encontrado em $PLUGINS_DIR"
fi
PLUGIN_VERSION=$(basename "$PLUGIN_JAR" | sed 's/com.totvs.tds.ecm.designer.model_//' | sed 's/\.jar//')
log_ok "Plugin Fluig detectado: versão $PLUGIN_VERSION"

if [ -z "$ECLIPSE_JAR" ]; then
    log_warn "Plugin ecm.designer.eclipse não encontrado — Fix 4 será pulado."
fi

if ! command -v curl &>/dev/null; then
    abort "curl não encontrado. Instale via: brew install curl"
fi
log_ok "curl disponível"

if ! command -v unzip &>/dev/null || ! command -v zip &>/dev/null; then
    abort "unzip/zip não encontrados."
fi
log_ok "zip/unzip disponíveis"

if ! command -v python3 &>/dev/null; then
    log_warn "python3 não encontrado — Fix 4 será pulado."
    PYTHON_OK=false
else
    log_ok "python3 disponível"
    PYTHON_OK=true
fi

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

# Verifica se já tem todas as flags
ALREADY_APPLIED=true
for flag in "${OPENS_NEEDED[@]}"; do
    if ! grep -qF "$flag" "$ECLIPSE_INI"; then
        ALREADY_APPLIED=false
        break
    fi
done

cp "$ECLIPSE_INI" "${ECLIPSE_INI}.bak" 2>/dev/null
log_info "Backup criado: eclipse.ini.bak"

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

# Adiciona as que faltam, após --add-modules
content = ''.join(result)
for flag in opens_needed:
    if flag not in content:
        # Insere após --add-modules=ALL-SYSTEM
        content = content.replace('--add-modules=ALL-SYSTEM\n',
                                  f'--add-modules=ALL-SYSTEM\n{flag}\n', 1)
        if flag not in content:
            content += f'{flag}\n'

with open(ini_path, 'w') as f:
    f.write(content)
PYEOF

log_ok "Flags --add-opens verificadas/adicionadas (sem duplicatas)"

# =============================================================================
# FIX 2: eclipse.ini — desativa reportNonDisposed (crash SWT)
# =============================================================================
log_section "Fix 2: eclipse.ini (SWT reportNonDisposed)"

SWT_FLAG="-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed"

if grep -qF "${SWT_FLAG}=false" "$ECLIPSE_INI"; then
    log_warn "reportNonDisposed já está como false. Pulando."
elif grep -qF "${SWT_FLAG}=true" "$ECLIPSE_INI"; then
    sed -i '' "s|${SWT_FLAG}=true|${SWT_FLAG}=false|g" "$ECLIPSE_INI"
    log_ok "reportNonDisposed=true → false"
else
    # Não existe a flag, adiciona como false
    echo "${SWT_FLAG}=false" >> "$ECLIPSE_INI"
    log_ok "reportNonDisposed=false adicionado"
fi

# =============================================================================
# FIX 3: rt.jar — JAX-WS RI 2.3.1 → 2.3.5
# =============================================================================
log_section "Fix 3: JAX-WS RI rt.jar (2.3.1 → 2.3.5)"

CURRENT_VERSION=""
if [ -f "$PLUGIN_JAR" ]; then
    CURRENT_VERSION=$(unzip -p "$PLUGIN_JAR" META-INF/lib/rt.jar 2>/dev/null | \
        unzip -p /dev/stdin META-INF/MANIFEST.MF 2>/dev/null | \
        grep "Build-Version" | awk '{print $2}' | tr -d '\r')
fi

if [ "$CURRENT_VERSION" = "JAX-WS RI 2.3.5" ]; then
    log_warn "rt.jar já está na versão 2.3.5. Pulando."
else
    log_info "Versão atual do rt.jar: ${CURRENT_VERSION:-desconhecida}"

    if [ -f "$RT_LOCAL" ]; then
        log_info "rt.jar 2.3.5 já existe em /tmp. Reutilizando."
    else
        log_info "Baixando JAX-WS RI 2.3.5 do Maven Central..."
        curl -fsSL --progress-bar "$RT_URL" -o "$RT_LOCAL"
        if [ $? -ne 0 ] || [ ! -f "$RT_LOCAL" ]; then
            abort "Falha ao baixar $RT_URL"
        fi
        log_ok "Download concluído: $(du -sh $RT_LOCAL | cut -f1)"
    fi

    VERSION_CHECK=$(unzip -p "$RT_LOCAL" META-INF/MANIFEST.MF 2>/dev/null | grep "Build-Version")
    if [[ "$VERSION_CHECK" != *"2.3.5"* ]]; then
        rm -f "$RT_LOCAL"
        abort "rt.jar baixado parece corrompido ou inválido."
    fi
    log_ok "rt.jar 2.3.5 verificado: $VERSION_CHECK"

    if [ ! -f "${PLUGIN_JAR}.bak" ]; then
        cp "$PLUGIN_JAR" "${PLUGIN_JAR}.bak"
        log_info "Backup criado: $(basename ${PLUGIN_JAR}).bak"
    else
        log_warn "Backup já existe. Mantendo backup original."
    fi

    log_info "Extraindo plugin..."
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    unzip -q "${PLUGIN_JAR}.bak" -d "$WORKDIR/extracted/"

    log_info "Substituindo rt.jar..."
    cp "$RT_LOCAL" "$WORKDIR/extracted/META-INF/lib/rt.jar"

    log_info "Reempacotando plugin..."
    cd "$WORKDIR/extracted"
    zip -qr "$WORKDIR/patched.jar" .
    cd - > /dev/null

    if [ ! -f "$WORKDIR/patched.jar" ]; then
        abort "Falha ao reempacotar o plugin."
    fi

    cp "$WORKDIR/patched.jar" "$PLUGIN_JAR"
    rm -rf "$WORKDIR"
    log_ok "Plugin atualizado com JAX-WS RI 2.3.5"
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
RHINO_LIBS=$(unzip -l "$ECLIPSE_JAR" 2>/dev/null | grep -oE "META-INF/lib/[^ ]*rhino[^ ]*\.jar" | sort -u | tr '\n' ' ')

if [ -z "$ECLIPSE_JAR" ]; then
    log_warn "Plugin ecm.designer.eclipse não encontrado. Pulando Fix 4."
elif unzip -l "$ECLIPSE_JAR" 2>/dev/null | grep -q "META-INF/lib/nashorn-core.jar"; then
    log_warn "nashorn-core já está no Bundle-ClassPath. Pulando Fix 4."
elif [ -n "$RHINO_LIBS" ]; then
    log_warn "O plugin já embarca motor JS próprio: ${RHINO_LIBS}"
    log_warn "Nashorn é desnecessário nesta versão. Pulando Fix 4 (nada será baixado)."
else
    # Download nashorn-core
    if [ -f "$NASHORN_LOCAL" ]; then
        log_info "nashorn-core já existe em /tmp. Reutilizando."
    else
        log_info "Baixando nashorn-core 15.4..."
        curl -fsSL "$NASHORN_URL" -o "$NASHORN_LOCAL"
        if [ $? -ne 0 ] || [ ! -f "$NASHORN_LOCAL" ]; then
            abort "Falha ao baixar nashorn-core."
        fi
        log_ok "nashorn-core baixado: $(du -sh $NASHORN_LOCAL | cut -f1)"
    fi

    # Download ASM (dependências em tempo de execução do nashorn-core)
    mkdir -p "$ASM_LOCAL"
    ASM_OK=true
    for artifact in "asm/9.5/asm-9.5.jar:asm.jar" "asm-commons/9.5/asm-commons-9.5.jar:asm-commons.jar" "asm-tree/9.5/asm-tree-9.5.jar:asm-tree.jar" "asm-util/9.5/asm-util-9.5.jar:asm-util.jar"; do
        src="${artifact%%:*}"
        dest="$ASM_LOCAL/${artifact##*:}"
        if [ -f "$dest" ]; then
            log_info "$(basename $dest) já existe. Reutilizando."
        else
            curl -fsSL "${ASM_BASE}/${src}" -o "$dest"
            if [ $? -ne 0 ] || [ ! -f "$dest" ]; then
                log_error "Falha ao baixar $(basename $dest)"
                ASM_OK=false
                break
            fi
        fi
    done

    if [ "$ASM_OK" = false ]; then
        log_error "Falha ao baixar dependências ASM. Fix 4 abortado."
    else
        if [ ! -f "${ECLIPSE_JAR}.bak.nashorn" ]; then
            cp "$ECLIPSE_JAR" "${ECLIPSE_JAR}.bak.nashorn"
            log_info "Backup criado: $(basename ${ECLIPSE_JAR}).bak.nashorn"
        else
            log_warn "Backup já existe. Mantendo backup original."
        fi

        WORKDIR_N="/tmp/fluig_nashorn_$$"
        mkdir -p "$WORKDIR_N/extracted"
        unzip -q "${ECLIPSE_JAR}.bak.nashorn" -d "$WORKDIR_N/extracted"

        cp "$NASHORN_LOCAL"             "$WORKDIR_N/extracted/META-INF/lib/nashorn-core.jar"
        cp "$ASM_LOCAL/asm.jar"         "$WORKDIR_N/extracted/META-INF/lib/"
        cp "$ASM_LOCAL/asm-commons.jar" "$WORKDIR_N/extracted/META-INF/lib/"
        cp "$ASM_LOCAL/asm-tree.jar"    "$WORKDIR_N/extracted/META-INF/lib/"
        cp "$ASM_LOCAL/asm-util.jar"    "$WORKDIR_N/extracted/META-INF/lib/"

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
        else
            cd "$WORKDIR_N/extracted"
            zip -qr "$WORKDIR_N/patched.jar" .
            cd - > /dev/null

            if [ ! -f "$WORKDIR_N/patched.jar" ]; then
                abort "Falha ao reempacotar o plugin (nashorn)."
            fi

            cp "$WORKDIR_N/patched.jar" "$ECLIPSE_JAR"
            rm -rf "$WORKDIR_N"
            log_ok "nashorn-core adicionado ao Bundle-ClassPath (ScriptEngine 'js' disponível no Java 21)"
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
else
    log_warn "Cache OSGi não encontrado (já estava limpo)"
fi

# =============================================================================
# Resumo final
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        Todas as correções aplicadas!     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  ✓  eclipse.ini — flags --add-opens Java 21 (sem duplicatas)"
echo "  ✓  eclipse.ini — SWT reportNonDisposed=false"
echo "  ✓  rt.jar      — JAX-WS RI 2.3.1 → 2.3.5"
echo "  ✓  nashorn     — Nashorn standalone no Bundle-ClassPath"
echo "  ✓  OSGi cache  — limpo"
echo ""
echo "  Eclipse:              $ECLIPSE_NAME"
echo "  Plugin Fluig versão:  $PLUGIN_VERSION"
echo ""
echo "  Abra o Eclipse normalmente."
echo "  A primeira inicialização pode ser um pouco mais lenta."
echo ""
echo "  Backups criados:"
echo "    • eclipse.ini.bak"
[ -n "$PLUGIN_JAR" ]    && echo "    • $(basename ${PLUGIN_JAR}).bak"
[ -n "$ECLIPSE_JAR" ]   && echo "    • $(basename ${ECLIPSE_JAR}).bak.nashorn"
echo ""
pause
