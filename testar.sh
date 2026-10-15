#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

REPETICOES="${REPETICOES:-10}"
PROG=./pix_a01

APROVADOS=0
REPROVADOS=0
FALHAS=()

verificar() {
    if [ "$2" -eq 1 ]; then
        APROVADOS=$((APROVADOS + 1))
    else
        REPROVADOS=$((REPROVADOS + 1))
        FALHAS+=("$1")
    fi
}

campo() {
    printf '%s\n' "$1" | sed -nE "s/.* $2=(-?[0-9]+).*/\1/p"
}

secao() {
    printf '\n==============================================================\n'
    printf ' %s\n' "$1"
    printf '==============================================================\n'
}

secao "Compilacao"
if gcc -std=c11 -Wall -Wextra -Wpedantic -O0 -pthread pix_a01.c -o pix_a01 2> avisos_compilacao.txt; then
    avisos=$(wc -l < avisos_compilacao.txt)
    echo "Compilou. Linhas de aviso do compilador: $avisos"
    verificar "compilacao com avisos" $([ "$avisos" -eq 0 ] && echo 1 || echo 0)
else
    cat avisos_compilacao.txt
    echo "ERRO: falha na compilacao"
    exit 1
fi
rm -f avisos_compilacao.txt
mkdir -p logs

secao "A) Condicao de corrida ($REPETICOES repeticoes por combinacao)"
VALORES_N="1 2 3 4 5 6 8 12 16 24 32 48 64 128 256"
VALORES_POOL="1 2 4 8"

printf 'modo,N,pool_pedida,pool_real,rodada,esperado,observado,divergencia,total_inicial,total_final,dinheiro_perdido\n' > resultados.csv

total_exec=0
for modo in sem com; do
    for pool in $VALORES_POOL; do
        for n in $VALORES_N; do
            pool_real=$(( n < pool ? n : pool ))
            for rodada in $(seq 1 "$REPETICOES"); do
                resumo=$("$PROG" "$modo" "$n" "$pool" 1 --silencioso | grep '^RESUMO' || true)
                if [ -z "$resumo" ]; then
                    verificar "A: execucao $modo N=$n pool=$pool rodada=$rodada nao gerou RESUMO" 0
                    continue
                fi
                esp=$(campo "$resumo" destino_esperado)
                obs=$(campo "$resumo" destino_observado)
                div=$(campo "$resumo" divergencia)
                ti=$(campo "$resumo" total_inicial)
                tf=$(campo "$resumo" total_final)
                perdido=$(( ti - tf ))
                printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$modo" "$n" "$pool" "$pool_real" \
                    "$rodada" "$esp" "$obs" "$div" "$ti" "$tf" "$perdido" >> resultados.csv
                total_exec=$((total_exec + 1))

                if [ "$modo" = com ]; then
                    verificar "A: com N=$n pool=$pool rodada=$rodada divergiu" \
                        $([ "$div" -eq 0 ] && [ "$ti" -eq "$tf" ] && echo 1 || echo 0)
                fi
                if [ "$modo" = sem ] && [ "$pool_real" -eq 1 ]; then
                    verificar "A: controle sem N=$n pool_real=1 rodada=$rodada divergiu" \
                        $([ "$div" -eq 0 ] && echo 1 || echo 0)
                fi
                verificar "A: $modo N=$n pool=$pool rodada=$rodada contabilidade inconsistente" \
                    $([ "$perdido" -eq "$div" ] && echo 1 || echo 0)
            done
        done
        printf '  modo=%s pool=%s concluido\n' "$modo" "$pool"
    done
done
echo "Execucoes da bateria A: $total_exec (gravadas em resultados.csv)"

secao "B) Resumo estatistico por combinacao (resumo.csv)"
awk -F, 'NR > 1 {
    k = $1 "," $2 "," $4
    if (!(k in qtd)) { ordem[++nk] = k; minv[k] = $7; maxv[k] = $7 }
    qtd[k]++; soma[k] += $7; esp[k] = $6
    if ($8 != 0) erro[k]++
    if ($7 < minv[k]) minv[k] = $7
    if ($7 > maxv[k]) maxv[k] = $7
}
END {
    print "modo,N,pool_real,execucoes,execucoes_com_erro,taxa_erro_pct,esperado,obs_medio,obs_min,obs_max,perda_media_pct"
    for (i = 1; i <= nk; i++) {
        k = ordem[i]; m = soma[k] / qtd[k]
        printf "%s,%d,%d,%.1f,%s,%.2f,%s,%s,%.1f\n", k, qtd[k], erro[k] + 0,
               100 * (erro[k] + 0) / qtd[k], esp[k], m, minv[k], maxv[k],
               100 * (esp[k] - m) / esp[k]
    }
}' resultados.csv > resumo.csv

printf '\n%-5s %-6s %-28s %s\n' "modo" "pool" "menor N com erro observado" "perda media com N=256"
for modo in sem com; do
    for pool in $VALORES_POOL; do
        primeiro=$(awk -F, -v m="$modo" -v p="$pool" \
            'NR>1 && $1==m && $3==p && $8!=0 {print $2; exit}' resultados.csv)
        perda=$(awk -F, -v m="$modo" -v p="$pool" \
            'NR>1 && $1==m && $2==256 && $3==p {print $11}' resumo.csv)
        printf '%-5s %-6s %-28s %s%%\n' "$modo" "$pool" "${primeiro:-nenhum}" "${perda:-?}"
    done
done

secao "C) Ordem FCFS"
printf 'N,pool,rodada,retiradas,ordem_fcfs_ok,concluidas,todas_ok,workers_validos\n' > fcfs.csv
for config in "6 2" "10 3" "20 4" "50 8" "100 16"; do
    set -- $config
    n=$1; pool=$2
    for rodada in 1 2 3; do
        log="logs/fcfs_N${n}_pool${pool}_r${rodada}.txt"
        "$PROG" com "$n" "$pool" 5 > "$log"

        retiradas=$(grep -c '^FCFS retirada' "$log" || true)
        fora_ordem=$(awk '/^FCFS retirada/ { k++; p = $6; sub(",", "", p); if ($3 != k || p != k) e++ }
                          END { print e + 0 }' "$log")
        concluidas=$(grep -c '^Concluido pedido' "$log" || true)
        nao_ok=$(grep '^Concluido pedido' "$log" | grep -vc ': OK$' || true)
        worker_invalido=$(awk -v p="$pool" '/^FCFS retirada/ { if ($8 < 1 || $8 > p) e++ }
                          END { print e + 0 }' "$log")

        ordem_ok=$([ "$retiradas" -eq "$n" ] && [ "$fora_ordem" -eq 0 ] && echo 1 || echo 0)
        todas_ok=$([ "$concluidas" -eq "$n" ] && [ "$nao_ok" -eq 0 ] && echo 1 || echo 0)
        workers_ok=$([ "$worker_invalido" -eq 0 ] && echo 1 || echo 0)
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$n" "$pool" "$rodada" "$retiradas" \
            "$ordem_ok" "$concluidas" "$todas_ok" "$workers_ok" >> fcfs.csv

        verificar "C: N=$n pool=$pool rodada=$rodada pedidos fora da ordem FCFS" "$ordem_ok"
        verificar "C: N=$n pool=$pool rodada=$rodada pedidos nao concluidos" "$todas_ok"
        verificar "C: N=$n pool=$pool rodada=$rodada worker fora da pool" "$workers_ok"
    done
    printf '  N=%-4s pool=%-3s 3 execucoes verificadas\n' "$n" "$pool"
done

secao "D) Debugging por sinal (SIGINT)"
testar_debug() {
    local n=$1 pool=$2 atraso=$3; shift 3
    local log="logs/debug_N${n}_pool${pool}.txt"
    local sinais=$#

    "$PROG" com "$n" "$pool" "$atraso" > "$log" &
    local pid=$!
    for espera in "$@"; do
        sleep "$espera"
        kill -INT "$pid" 2> /dev/null || true
    done
    local status=0
    wait "$pid" || status=$?

    local debugs resumo div fila_errada
    debugs=$(grep -c '^===== DEBUG DA FILA' "$log" || true)
    resumo=$(grep '^RESUMO' "$log" || true)
    div=$(campo "$resumo" divergencia)

    fila_errada=$(awk '
        /^Concluidas:/ { split($0, a, "Aguardando: "); aguardando = a[2] + 0 }
        /^Fila FCFS/ {
            sub(/^Fila FCFS \(do primeiro ao ultimo\): /, "")
            if ($0 == "vazia") { if (aguardando != 0) e++; next }
            n = split($0, it, " -> "); ant = 0; lidos = 0
            for (i = 1; i <= n; i++)
                if (it[i] ~ /^[0-9]+$/) { if (it[i] + 0 <= ant) e++; ant = it[i] + 0; lidos++ }
            if (aguardando <= 25 && lidos != aguardando) e++
        }
        END { print e + 0 }' "$log")

    printf '  N=%-3s pool=%s: %d sinais enviados, %d debugs impressos, status=%d, divergencia=%s\n' \
        "$n" "$pool" "$sinais" "$debugs" "$status" "${div:-?}"

    verificar "D: N=$n processo foi encerrado pelo SIGINT (status $status)" \
        $([ "$status" -eq 0 ] && echo 1 || echo 0)
    verificar "D: N=$n esperava $sinais debugs, saiu $debugs" \
        $([ "$debugs" -eq "$sinais" ] && echo 1 || echo 0)
    verificar "D: N=$n resultado incorreto apos os sinais" \
        $([ -n "$div" ] && [ "$div" -eq 0 ] && echo 1 || echo 0)
    verificar "D: N=$n fila impressa fora de ordem ou com contagem errada" \
        $([ "$fila_errada" -eq 0 ] && echo 1 || echo 0)
}

testar_debug 12 2 300  0.5 0.5 0.5
testar_debug 30 3 200  0.3 0.5 0.5 0.5
testar_debug 60 4 100  0.2 0.3

secao "E) Entradas invalidas e casos limite"
deve_falhar() {
    local desc=$1; shift
    if "$PROG" "$@" > /dev/null 2>&1; then
        verificar "E: aceitou entrada invalida: $desc" 0
        printf '  [FALHOU] aceitou: %s\n' "$desc"
    else
        verificar "E: $desc" 1
        printf '  [ok] rejeitou: %s\n' "$desc"
    fi
}
deve_falhar "sem argumentos"
deve_falhar "modo desconhecido"         talvez 10 2 1
deve_falhar "N = 0"                     com 0 2 1
deve_falhar "N acima do maximo"         com 10001 2 1
deve_falhar "N nao numerico"            com abc 2 1
deve_falhar "pool = 0"                  com 10 0 1
deve_falhar "pool acima do maximo"      com 10 129 1
deve_falhar "atraso negativo"           com 10 2 -1
deve_falhar "opcao desconhecida"        com 10 2 1 --verboso
deve_falhar "argumentos a mais"         com 10 2 1 --silencioso extra

limite() {
    local desc=$1 modo=$2 n=$3 pool=$4 atraso=$5 deve_div=$6
    local resumo div ok
    resumo=$("$PROG" "$modo" "$n" "$pool" "$atraso" --silencioso | grep '^RESUMO' || true)
    div=$(campo "$resumo" divergencia)
    if [ -z "$div" ]; then ok=0
    elif [ "$deve_div" -eq 1 ]; then ok=$([ "$div" -gt 0 ] && echo 1 || echo 0)
    else ok=$([ "$div" -eq 0 ] && echo 1 || echo 0)
    fi
    verificar "E: $desc (divergencia=${div:-?})" "$ok"
    printf '  [%s] %s -> divergencia=%s\n' "$([ "$ok" -eq 1 ] && echo ok || echo FALHOU)" "$desc" "${div:-?}"
}
limite "N maximo (10000), pool maxima (128), sem protecao" sem 10000 128 0 1
limite "N=1000, pool maxima (128), com protecao"          com 1000  128 0 0
limite "pool maior que N (reduzida para N)"               com 5     50  1 0
limite "atraso zero, com protecao"                        com 200   8   0 0

secao "RESULTADO FINAL"
total=$((APROVADOS + REPROVADOS))
printf 'Verificacoes: %d | aprovadas: %d | reprovadas: %d\n' "$total" "$APROVADOS" "$REPROVADOS"
printf 'Execucoes do programa na bateria A: %d\n' "$total_exec"
if [ "$REPROVADOS" -gt 0 ]; then
    printf '\nFalhas:\n'
    printf '  - %s\n' "${FALHAS[@]}" | head -50
    exit 1
fi
printf 'Todas as verificacoes passaram.\n'
exit 0
