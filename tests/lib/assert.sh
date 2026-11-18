#!/bin/bash
# Mini-framework de asserções. Sem dependências externas.

if [ -t 1 ]; then
    T_GREEN='\033[0;32m'; T_RED='\033[0;31m'; T_DIM='\033[2m'; T_BOLD='\033[1m'; T_NC='\033[0m'
else
    T_GREEN=''; T_RED=''; T_DIM=''; T_BOLD=''; T_NC=''
fi

CASES_RUN=0
CASES_FAILED=0
ASSERTS_RUN=0
ASSERTS_FAILED=0
CASE_FAILED=0
CURRENT_CASE=""
FAILED_CASES=()

begin_case() {
    CURRENT_CASE="$1"
    CASE_FAILED=0
    CASES_RUN=$((CASES_RUN + 1))
    printf "\n${T_BOLD}%s${T_NC}\n" "▸ $1"
}

end_case() {
    if [ "$CASE_FAILED" -eq 0 ]; then
        printf "  ${T_GREEN}PASS${T_NC}\n"
    else
        CASES_FAILED=$((CASES_FAILED + 1))
        FAILED_CASES+=("$CURRENT_CASE")
        printf "  ${T_RED}FAIL${T_NC}\n"
    fi
}

_pass() {
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    printf "  ${T_GREEN}✓${T_NC} %s\n" "$1"
}

_fail() {
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    CASE_FAILED=1
    printf "  ${T_RED}✗${T_NC} %s\n" "$1"
    [ -n "$2" ] && printf "    ${T_DIM}%s${T_NC}\n" "$2"
    return 0
}

assert_eq() { # <descrição> <obtido> <esperado>
    if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "esperado '$3', obtido '$2'"; fi
}

assert_ne() {
    if [ "$2" != "$3" ]; then _pass "$1"; else _fail "$1" "não deveria ser '$3'"; fi
}

assert_contains() { # <descrição> <texto> <trecho>
    case "$2" in *"$3"*) _pass "$1" ;; *) _fail "$1" "não contém '$3'" ;; esac
}

assert_not_contains() {
    case "$2" in *"$3"*) _fail "$1" "contém '$3' e não deveria" ;; *) _pass "$1" ;; esac
}

assert_file_contains() { # <descrição> <arquivo> <trecho literal>
    if [ -f "$2" ] && grep -qF -- "$3" "$2"; then _pass "$1"
    else _fail "$1" "'$3' ausente em $2"; fi
}

assert_file_not_contains() {
    if [ -f "$2" ] && grep -qF -- "$3" "$2"; then _fail "$1" "'$3' presente em $2"
    else _pass "$1"; fi
}

assert_file_exists() {
    if [ -f "$2" ]; then _pass "$1"; else _fail "$1" "arquivo ausente: $2"; fi
}

assert_dir_exists() {
    if [ -d "$2" ]; then _pass "$1"; else _fail "$1" "diretório ausente: $2"; fi
}

assert_dir_absent() {
    if [ -d "$2" ]; then _fail "$1" "diretório ainda existe: $2"; else _pass "$1"; fi
}

assert_count() { # <descrição> <arquivo> <trecho> <n esperado>
    local n
    n=$(grep -cF -- "$3" "$2" 2>/dev/null | tr -d ' ')
    if [ "$n" = "$4" ]; then _pass "$1"; else _fail "$1" "esperado $4 ocorrência(s) de '$3', achei ${n:-0}"; fi
}

assert_same_file() { # <descrição> <a> <b>
    if cmp -s "$2" "$3"; then _pass "$1"; else _fail "$1" "arquivos diferem: $2 ≠ $3"; fi
}

assert_differ() {
    if cmp -s "$2" "$3"; then _fail "$1" "arquivos idênticos e não deveriam ser"; else _pass "$1"; fi
}

summary() {
    printf "\n${T_BOLD}────────────────────────────────────────${T_NC}\n"
    printf "Casos:     %s (%s falharam)\n" "$CASES_RUN" "$CASES_FAILED"
    printf "Asserções: %s (%s falharam)\n" "$ASSERTS_RUN" "$ASSERTS_FAILED"
    if [ "$CASES_FAILED" -gt 0 ]; then
        printf "\n${T_RED}Casos com falha:${T_NC}\n"
        for c in "${FAILED_CASES[@]}"; do printf "  • %s\n" "$c"; done
        printf "\n${T_RED}FALHOU${T_NC}\n"
        return 1
    fi
    printf "\n${T_GREEN}TUDO PASSOU${T_NC}\n"
    return 0
}
