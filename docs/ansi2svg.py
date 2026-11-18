#!/usr/bin/env python3
"""Converte uma captura ANSI do terminal em um SVG com cara de janela.

Uso: ansi2svg.py <captura.raw> <saida.svg> <titulo> [primeira_linha] [ultima_linha]

As linhas são 1-indexadas sobre o texto já limpo (sem \\r e sem escapes que
não sejam de cor). Serve para manter os prints do README reproduzíveis:
regenerar é rodar `docs/gerar-prints.sh`, não tirar screenshot à mão.
"""
import html
import re
import sys

# Paleta escura, legível tanto no tema claro quanto no escuro do GitHub
BG = "#11151c"
BG_BAR = "#0b0e14"
BORDER = "#2b323d"
FG = "#e4e7eb"
COLORS = {
    "0;32": "#3fb950",  # verde  [OK]
    "1;33": "#d29922",  # amarelo [AVISO]
    "0;31": "#f85149",  # vermelho [ERRO]
    "0;34": "#58a6ff",  # azul   [INFO] e títulos de seção
}

FONT = ("ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, "
        "'Liberation Mono', monospace")
FONT_SIZE = 13
CHAR_W = 7.82
LINE_H = 19
PAD_X = 16
PAD_TOP = 40          # altura da barra de título
PAD_BOTTOM = 14

SGR = re.compile(r"\x1b\[([0-9;]*)m")
OTHER_ESC = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][B0]|\x1b[=>]")


def limpar(raw):
    """Remove escapes que não são de cor, \\r e o ruído do `script`."""
    raw = raw.replace("\r\n", "\n").replace("\r", "")
    # Protege os SGR antes de varrer os outros escapes
    marcas = []

    def guarda(m):
        marcas.append(m.group(0))
        return "\x00%d\x00" % (len(marcas) - 1)

    raw = SGR.sub(guarda, raw)
    raw = OTHER_ESC.sub("", raw)
    # Limpa ESC solto ANTES de restaurar as marcas: depois, o ESC das
    # próprias sequências de cor seria removido e elas virariam texto.
    raw = raw.replace("\x1b", "")
    raw = re.sub(r"\x00(\d+)\x00", lambda m: marcas[int(m.group(1))], raw)
    return raw


def em_trechos(linha):
    """Quebra uma linha em (texto, cor) seguindo os códigos SGR."""
    out, cor, pos = [], None, 0
    for m in SGR.finditer(linha):
        if m.start() > pos:
            out.append((linha[pos:m.start()], cor))
        codigo = m.group(1)
        cor = None if codigo in ("", "0") else COLORS.get(codigo, cor)
        pos = m.end()
    if pos < len(linha):
        out.append((linha[pos:], cor))
    return [t for t in out if t[0]]


def visivel(linha):
    return SGR.sub("", linha)


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    origem, destino, titulo = sys.argv[1], sys.argv[2], sys.argv[3]
    ini = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    fim = int(sys.argv[5]) if len(sys.argv) > 5 else 10 ** 6

    with open(origem, "rb") as f:
        texto = limpar(f.read().decode("utf-8", "replace"))

    linhas = texto.split("\n")[ini - 1:fim]
    # Tira linhas em branco das pontas
    while linhas and not visivel(linhas[0]).strip():
        linhas.pop(0)
    while linhas and not visivel(linhas[-1]).strip():
        linhas.pop()

    cols = max((len(visivel(l)) for l in linhas), default=40)
    cols = max(cols, len(titulo) + 10)
    largura = round(cols * CHAR_W + PAD_X * 2)
    altura = round(PAD_TOP + len(linhas) * LINE_H + PAD_BOTTOM)

    p = []
    p.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
             'viewBox="0 0 %d %d" role="img" aria-label="%s">'
             % (largura, altura, largura, altura, html.escape(titulo)))
    p.append('<rect width="%d" height="%d" rx="8" fill="%s" stroke="%s"/>'
             % (largura, altura, BG, BORDER))
    p.append('<path d="M0 8a8 8 0 0 1 8-8h%d a8 8 0 0 1 8 8v22H0z" fill="%s"/>'
             % (largura - 16, BG_BAR))
    p.append('<line x1="0" y1="30" x2="%d" y2="30" stroke="%s"/>' % (largura, BORDER))
    for i, c in enumerate(("#f85149", "#d29922", "#3fb950")):
        p.append('<circle cx="%d" cy="15" r="5" fill="%s"/>' % (18 + i * 18, c))
    p.append('<text x="%d" y="19" font-family=%s font-size="11" fill="#8b949e" '
             'text-anchor="middle">%s</text>'
             % (largura // 2, '"%s"' % FONT, html.escape(titulo)))

    y = PAD_TOP + 2
    for linha in linhas:
        trechos = em_trechos(linha)
        if trechos:
            p.append('<text x="%d" y="%d" font-family=%s font-size="%d" '
                     'fill="%s" xml:space="preserve">'
                     % (PAD_X, y, '"%s"' % FONT, FONT_SIZE, FG))
            for txt, cor in trechos:
                if cor:
                    p.append('<tspan fill="%s">%s</tspan>' % (cor, html.escape(txt)))
                else:
                    p.append('<tspan>%s</tspan>' % html.escape(txt))
            p.append("</text>")
        y += LINE_H
    p.append("</svg>")

    with open(destino, "w", encoding="utf-8") as f:
        f.write("\n".join(p) + "\n")
    print("%s  (%d linhas, %dx%d)" % (destino, len(linhas), largura, altura))


if __name__ == "__main__":
    main()
