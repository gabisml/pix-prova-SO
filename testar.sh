#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
gcc -std=c11 -Wall -Wextra -Wpedantic -O0 -pthread pix_a01.c -o pix_a01

printf 'modo,N,pool,rodada,esperado,observado,divergencia\n' > resultados.csv
for modo in sem com; do
    for n in 1 2 3 4 8 16 32 64; do
        for rodada in 1 2 3 4 5; do
            saida=$(./pix_a01 "$modo" "$n" 4 1 --silencioso)
            resumo=$(printf '%s\n' "$saida" | grep '^RESUMO')
            esperado=$(echo "$resumo" | sed -E 's/.*destino_esperado=([0-9]+).*/\1/')
            observado=$(echo "$resumo" | sed -E 's/.*destino_observado=([0-9]+).*/\1/')
            divergencia=$(echo "$resumo" | sed -E 's/.*divergencia=([0-9]+).*/\1/')
            printf '%s,%s,%s,%s,%s,%s,%s\n' "$modo" "$n" "$(( n < 4 ? n : 4 ))" "$rodada" "$esperado" "$observado" "$divergencia" >> resultados.csv
        done
    done
done
printf 'Testes finalizados. Veja resultados.csv.\n'
