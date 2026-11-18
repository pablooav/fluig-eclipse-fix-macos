#!/usr/bin/env python3
"""Gera MANIFEST.MF sintéticos para os fixtures do plugin ecm.designer.eclipse.

Uso: mkmanifest.py <saida> <flavor> <versao>

Flavors:
  plain      Bundle-ClassPath curto, sem dobra, com a âncora jaxws-api.jar
  folded     Bundle-ClassPath longo, dobrado em 72 bytes, com a âncora
             GARANTIDAMENTE partida no meio por uma continuação
  no-anchor  Bundle-ClassPath sem jaxws-api.jar (o Fix 4 deve recusar)
  nashorn    já contém nashorn-core.jar (o Fix 4 deve pular)

A dobra segue a spec do JAR: no máximo 72 bytes por linha, continuações
começando com um único espaço.
"""
import sys

ANCHOR = "META-INF/lib/jaxws-api.jar"
WIDTH = 72


def fold(text):
    """Dobra uma linha lógica em linhas físicas de no máximo 72 bytes."""
    b = text.encode("utf-8")
    if len(b) <= WIDTH:
        return [b.decode("utf-8")]
    out = [b[:WIDTH].decode("utf-8")]
    rest = b[WIDTH:]
    while rest:
        out.append(" " + rest[: WIDTH - 1].decode("utf-8"))
        rest = rest[WIDTH - 1:]
    return out


def anchor_is_split(header):
    """True se a âncora cruzar um limite de dobra na linha lógica dada."""
    start = header.index(ANCHOR)
    end = start + len(ANCHOR)
    # Limites de dobra em bytes da linha lógica: 72, 72+71, 72+142, ...
    pos = WIDTH
    while pos < len(header.encode("utf-8")):
        if start < pos < end:
            return True
        pos += WIDTH - 1
    return False


def classpath(flavor):
    base = [
        "META-INF/lib/policy.jar",
        "META-INF/lib/activation.jar",
        "META-INF/lib/rt.jar",
        "META-INF/lib/javax.jws-api.jar",
        "META-INF/lib/jaxb-runtime.jar",
        "META-INF/lib/jaxb-api.jar",
    ]
    if flavor == "no-anchor":
        return base + ["META-INF/lib/xstream.jar"]
    if flavor == "nashorn":
        return base + [ANCHOR, "META-INF/lib/nashorn-core.jar"]
    if flavor == "plain":
        return [".", ANCHOR, "META-INF/lib/xstream.jar"]
    if flavor == "folded":
        # Adiciona entradas de preenchimento até a âncora cair em cima de
        # uma dobra. Assim o teste cobre exatamente o bug que o script corrige.
        for pad in range(0, 60):
            entries = base + ["META-INF/lib/pad%02d.jar" % i for i in range(pad)]
            entries = entries + [ANCHOR, "META-INF/lib/xstream.jar"]
            header = "Bundle-ClassPath: " + ",".join(entries)
            if anchor_is_split(header):
                return entries
        raise SystemExit("mkmanifest: não consegui partir a âncora")
    raise SystemExit("mkmanifest: flavor desconhecido %r" % flavor)


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    out_path, flavor, version = sys.argv[1], sys.argv[2], sys.argv[3]

    entries = classpath(flavor)
    logical = [
        "Manifest-Version: 1.0",
        "Bundle-ManifestVersion: 2",
        "Bundle-Name: Fluig Designer Eclipse (fixture)",
        "Bundle-SymbolicName: com.totvs.tds.ecm.designer.eclipse;singleton:=true",
        "Bundle-Version: " + version,
        "Bundle-ClassPath: " + ",".join(entries),
        "Require-Bundle: org.eclipse.ui,org.eclipse.core.runtime",
        "Bundle-RequiredExecutionEnvironment: JavaSE-21",
    ]

    physical = []
    for line in logical:
        physical.extend(fold(line))

    with open(out_path, "w", newline="") as f:
        f.write("\r\n".join(physical) + "\r\n\r\n")


if __name__ == "__main__":
    main()
