#!/bin/bash
# Constrói instalações de Eclipse sintéticas e um cache Maven falso.
# Nada aqui toca /Applications nem a rede.

FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# eclipse.ini
# -----------------------------------------------------------------------------
# Variantes:
#   completo      → como vem o EPP 2026-x (tem --add-modules, SWT já false)
#   sem-modules   → sem a linha --add-modules=ALL-SYSTEM (flags vão para o fim)
#   swt-true      → reportNonDisposed=true
#   swt-ausente   → sem a flag SWT
#   duplicado     → --add-opens repetidos e SWT repetido 3x
fixture_ini() {
    local app="$1" variant="${2:-completo}"
    local ini="$app/Contents/Eclipse/eclipse.ini"

    cat > "$ini" <<'EOF'
-startup
../Eclipse/plugins/org.eclipse.equinox.launcher_1.7.100.v20251111-0406.jar
--launcher.library
../Eclipse/plugins/org.eclipse.equinox.launcher.cocoa.macosx.aarch64_1.2.1400.v20250801-0854
-product
org.eclipse.epp.package.jee.product
--launcher.appendVmargs
-vm
../Eclipse/plugins/org.eclipse.justj.openjdk.hotspot.jre.full.macosx.aarch64_21.0.12.v20260826-1216/jre/lib/libjli.dylib
-vmargs
-Dosgi.requiredJavaVersion=21
-XX:+UseG1GC
EOF

    case "$variant" in
        completo)
            cat >> "$ini" <<'EOF'
--add-modules=ALL-SYSTEM
-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=false
-XstartOnFirstThread
EOF
            ;;
        sem-modules)
            cat >> "$ini" <<'EOF'
-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=false
-XstartOnFirstThread
EOF
            ;;
        swt-true)
            cat >> "$ini" <<'EOF'
--add-modules=ALL-SYSTEM
-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=true
-XstartOnFirstThread
EOF
            ;;
        swt-ausente)
            cat >> "$ini" <<'EOF'
--add-modules=ALL-SYSTEM
-XstartOnFirstThread
EOF
            ;;
        duplicado)
            cat >> "$ini" <<'EOF'
--add-modules=ALL-SYSTEM
--add-opens=java.base/java.util=ALL-UNNAMED
--add-opens=java.base/java.util=ALL-UNNAMED
--add-opens=java.base/java.text=ALL-UNNAMED
--add-opens=java.base/java.text=ALL-UNNAMED
--add-opens=java.base/java.text=ALL-UNNAMED
-XstartOnFirstThread
-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=false
-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=false
-Dorg.eclipse.swt.graphics.Resource.reportNonDisposed=false
EOF
            ;;
        *)
            echo "fixture_ini: variante desconhecida '$variant'" >&2
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Instalação completa
# -----------------------------------------------------------------------------
# fixture_eclipse <root> <nome-sem-.app> [variante-ini]  → imprime o caminho
fixture_eclipse() {
    local root="$1" name="$2" variant="${3:-completo}"
    local app="$root/$name.app"
    mkdir -p "$app/Contents/Eclipse/plugins"
    mkdir -p "$app/Contents/Eclipse/configuration/org.eclipse.osgi/framework"
    echo "cache osgi" > "$app/Contents/Eclipse/configuration/org.eclipse.osgi/.manager"
    fixture_ini "$app" "$variant" || return 1
    printf '%s\n' "$app"
}

# -----------------------------------------------------------------------------
# Jars
# -----------------------------------------------------------------------------
# Empacota um diretório como jar (caminho de saída absoluto).
_zip_dir() {
    local out="$1" src="$2"
    rm -f "$out"
    ( cd "$src" && zip -qrX "$out" . )
}

# Cria um jar JAX-WS RI com o Build-Version pedido.
# fixture_rt_jar <saida.jar> <versao>
fixture_rt_jar() {
    local out="$1" version="$2"
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/META-INF" "$tmp/com/sun/xml/ws/model"
    printf 'Manifest-Version: 1.0\r\nBuild-Id: %s\r\nBuild-Version: JAX-WS RI %s\r\nImplementation-Version: %s\r\n\r\n' \
        "$version" "$version" "$version" > "$tmp/META-INF/MANIFEST.MF"
    echo "classe falsa do Injector ($version)" > "$tmp/com/sun/xml/ws/model/Injector.class"
    _zip_dir "$out" "$tmp"
    rm -rf "$tmp"
}

# fixture_model_plugin <app> <versao-plugin> <versao-rt>
# Gera com.totvs.tds.ecm.designer.model_<v>.jar com META-INF/lib/rt.jar dentro.
fixture_model_plugin() {
    local app="$1" version="$2" rt_version="$3"
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/META-INF/lib" "$tmp/com/totvs"
    printf 'Manifest-Version: 1.0\r\nBundle-SymbolicName: com.totvs.tds.ecm.designer.model;singleton:=true\r\nBundle-Version: %s\r\nBundle-ClassPath: .,META-INF/lib/rt.jar\r\n\r\n' \
        "$version" > "$tmp/META-INF/MANIFEST.MF"
    echo "marcador para detectar perda de conteudo" > "$tmp/com/totvs/marcador.txt"
    echo "outra lib" > "$tmp/META-INF/lib/xstream.jar"
    fixture_rt_jar "$tmp/META-INF/lib/rt.jar" "$rt_version"
    _zip_dir "$app/Contents/Eclipse/plugins/com.totvs.tds.ecm.designer.model_${version}.jar" "$tmp"
    rm -rf "$tmp"
}

# fixture_eclipse_plugin <app> <versao-plugin> <flavor>
# flavor: plain | folded | no-anchor | nashorn | rhino
fixture_eclipse_plugin() {
    local app="$1" version="$2" flavor="$3"
    local manifest_flavor="$flavor"
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/META-INF/lib" "$tmp/com/totvs"

    case "$flavor" in
        rhino) manifest_flavor="plain" ;;
    esac

    python3 "$FIXTURES_DIR/mkmanifest.py" "$tmp/META-INF/MANIFEST.MF" "$manifest_flavor" "$version" || return 1

    echo "marcador designer.eclipse" > "$tmp/com/totvs/marcador.txt"
    echo "jaxws api falso" > "$tmp/META-INF/lib/jaxws-api.jar"
    echo "xstream falso"   > "$tmp/META-INF/lib/xstream.jar"

    if [ "$flavor" = "rhino" ]; then
        echo "rhino falso"        > "$tmp/META-INF/lib/fluig-rhino.jar"
        echo "rhino engine falso" > "$tmp/META-INF/lib/rhino-js-engine.jar"
    fi
    if [ "$flavor" = "nashorn" ]; then
        echo "nashorn ja presente" > "$tmp/META-INF/lib/nashorn-core.jar"
    fi

    _zip_dir "$app/Contents/Eclipse/plugins/com.totvs.tds.ecm.designer.eclipse_${version}.jar" "$tmp"
    rm -rf "$tmp"
}

# -----------------------------------------------------------------------------
# Cache Maven falso (para rodar com --offline, sem rede)
# -----------------------------------------------------------------------------
fixture_cache() {
    local cache="$1"
    mkdir -p "$cache/fluig_asm"
    fixture_rt_jar "$cache/jaxws-rt-2.3.5.jar" "2.3.5"

    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/META-INF/services" "$tmp/org/openjdk/nashorn"
    printf 'Manifest-Version: 1.0\r\nImplementation-Version: 15.4\r\n\r\n' > "$tmp/META-INF/MANIFEST.MF"
    echo "org.openjdk.nashorn.api.scripting.NashornScriptEngineFactory" \
        > "$tmp/META-INF/services/javax.script.ScriptEngineFactory"
    echo "nashorn falso" > "$tmp/org/openjdk/nashorn/engine.class"
    _zip_dir "$cache/nashorn-core-15.4.jar" "$tmp"
    rm -rf "$tmp"

    local a
    for a in asm asm-commons asm-tree asm-util; do
        tmp=$(mktemp -d)
        mkdir -p "$tmp/META-INF" "$tmp/org/objectweb/asm"
        printf 'Manifest-Version: 1.0\r\nImplementation-Version: 9.5\r\n\r\n' > "$tmp/META-INF/MANIFEST.MF"
        echo "$a falso" > "$tmp/org/objectweb/asm/$a.class"
        _zip_dir "$cache/fluig_asm/$a.jar" "$tmp"
        rm -rf "$tmp"
    done
}
