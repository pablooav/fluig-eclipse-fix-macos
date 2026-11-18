# Política de segurança

## Como reportar

**Não abra uma issue pública** para falhas de segurança.

Use **[Security → Report a vulnerability](https://github.com/pablooav/fluig-eclipse-fix-macos/security/advisories/new)**
no próprio repositório. O relato fica privado até existir correção.

Retorno esperado em até 7 dias. Como é um projeto mantido por uma pessoa só, não
há SLA formal.

## O que este script faz na sua máquina

Vale conhecer o alcance antes de rodar:

| Ação | Alcance |
|---|---|
| Reescreve o `eclipse.ini` | apenas dentro do `.app` escolhido |
| Reempacota jars em `plugins/` | apenas `com.totvs.tds.ecm.designer.{model,eclipse}_*.jar` |
| Apaga `configuration/org.eclipse.osgi` | apenas do `.app` escolhido |
| Baixa artefatos | somente de `repo1.maven.org`, por HTTPS |
| Escreve temporários | em `$TMPDIR` |

O script **não** pede senha, **não** usa `sudo`, **não** lê credenciais, **não**
envia nada para lugar nenhum e **não** toca em nada fora do `.app` indicado.
Tudo que altera ganha backup antes.

## Limitações conhecidas

**Os downloads não têm verificação de checksum.** O `rt.jar` é conferido pelo
`Build-Version` do manifesto depois de baixado, o que detecta arquivo corrompido
ou errado — mas não é uma verificação criptográfica. O `nashorn-core` e os jars
ASM não têm conferência alguma além do próprio HTTPS.

Na prática o risco é baixo: o transporte é TLS contra o Maven Central e as
coordenadas são fixas no script. Mas um checksum fixado (`SHA-256` por artefato)
seria mais forte, e é a próxima melhoria prevista. Até lá, quem quiser isolar
totalmente o passo de rede pode popular o `--cache-dir` à mão, com artefatos
conferidos por conta própria, e rodar com `--offline`.

**Rode apenas a partir de uma cópia que você confira.** Como qualquer script que
modifica sua instalação, leia antes. Ele é intencionalmente legível e cada
correção está documentada no README com o motivo.

## Escopo

Entram aqui: execução de código indesejada, escrita fora do `.app` indicado,
exfiltração de dados, corrupção de instalação sem backup recuperável.

Não entram: falhas do próprio plugin da TOTVS, falhas do Eclipse, e problemas
de certificado ou DNS do seu ambiente Fluig.
