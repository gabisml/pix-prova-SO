# Primeira Avaliacao (A01) -- SO

## Emulando o Sistema de Funcionamento do PIX

Projeto em C para estudar **threads, exclusao mutua, condicao de corrida, escalonamento FCFS e sinais POSIX**. Trata-se de uma **simulacao local**, nao de uma implementacao real do PIX nem de um sistema distribuido de producao.

Alunos: Gabrielle Siqueira Moreira Leão e Wevton Junior Fagundes Santana

## 1. Preparacao e execucao

Requisitos: Linux, GCC, biblioteca POSIX Threads e semaforos POSIX.

```bash
gcc -std=c11 -Wall -Wextra -Wpedantic -O0 -pthread pix_a01.c -o pix_a01
```

```bash
./pix_a01 sem 8 4 1

./pix_a01 com 8 4 1

./pix_a01 com 20 3 500
```

Uso geral:

```text
./pix_a01 sem|com N tamanho_da_pool atraso_ms [--silencioso]
```

- `sem`: modo **sem protecao da transacao completa** (a atualizacao do saldo pode ser perdida).
- `com`: modo **com protecao da transacao completa** por mutex.
- `N`: numero de contas remetentes / requisicoes, entre 1 e 10.000.
- `tamanho_da_pool`: numero de workers, entre 1 e 128 (reduzido para N quando for maior que N).
- `atraso_ms`: tempo simulado por requisicao **antes** do trecho critico. Para demos: 300 a 500 ms. Para testes rapidos: 1 ms.
- `--silencioso`: omite mensagens individuais de cada requisicao; mantem cabecalho, debugging e resumo.

Para repetir os testes:

```bash
bash testar.sh
```

## 3. Parte 2  Protecao e escalonamento FCFS

### Protecao minima

No modo `com`, a thread chama `pthread_mutex_lock(&transacao)` **antes de verificar e atualizar** as contas e `pthread_mutex_unlock(&transacao)` ao final. Portanto, duas threads nao podem executar simultaneamente a regiao completa de transferencia. O mutex protege a consistencia do dinheiro transferido.

Este e o mecanismo didatico mais simples, mas serializa todas as transferencias na mesma secao critica. Em uma aplicacao real seriam necessarias estruturas e garantias adicionais.

### Thread pool e FCFS

- A `main` cria uma **quantidade fixa K de workers** com `pthread_create()`.
- Cada pedido recebe um identificador crescente `1, 2, ..., N` e e inserido no final de uma fila FIFO.
- Um semaforo sem nome (`sem_init`, `sem_wait`, `sem_post`) informa que existem pedidos disponiveis.
- Um mutex protege os indices da fila (`inicio`, `fim`) e os contadores.
- Um worker livre retira **o pedido mais antigo da fila**. Se N > K, os pedidos restantes aguardam.
- Ao final, a `main` coloca comandos de encerramento na mesma fila e aguarda os workers com `pthread_join()`.

**FCFS governa a ordem de retirada/atribuicao**, e nao necessariamente a ordem de conclusao dos pedidos, pois os workers operam concorrentemente.

Exemplo observado, `N=6`, `K=2`:

```text
FCFS retirada 1 -> pedido 1
FCFS retirada 2 -> pedido 2
FCFS retirada 3 -> pedido 3
FCFS retirada 4 -> pedido 4
FCFS retirada 5 -> pedido 5
FCFS retirada 6 -> pedido 6
```

## 4. Parte 3 Debugging por sinais

O programa instala um tratador com `sigaction()` para `SIGINT` (Ctrl+C) e `SIGUSR1`. O tratador nao chama `printf`, `read` ou locks; ele apenas atribui 1 a uma variavel `volatile sig_atomic_t`.

A `main` verifica a variavel periodicamente e, quando necessario, imprime **fora do tratador**:

1. total de requisicoes concluidas;
2. total aguardando na fila;
3. pedidos em atendimento e seus workers;
4. sequencia de pedidos ainda na fila FCFS.

Teste manual:

```bash
./pix_a01 com 12 2 300
```

Outra maneira de acionar o debug em outro terminal e `kill -USR1 <pid>` (o PID aparece no inicio da execucao). `SIGINT` foi redefinido para solicitar debug, em vez de encerrar o programa.

Exemplo real registrado em `debug_exemplo.txt`:

```text
Concluidas: 0/12 | Aguardando: 10
Em atendimento: [worker 1: pedido 1] [worker 2: pedido 2]
Fila FCFS (do primeiro ao ultimo): 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10 -> 11 -> 12
```

As pausas sao simuladas com `nanosleep()`. Isso facilita visualizar a fila, sem colocar esperas no tratador. Uma demonstracao mais simples do principio e: `SIGINT` altera uma flag; a `main` realiza o debug quando pode faze-lo com seguranca.

