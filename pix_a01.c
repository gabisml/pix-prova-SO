#define _DEFAULT_SOURCE
#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAX_N 10000
#define MAX_POOL 128
#define SALDO_INICIAL 100L
#define VALOR_PIX 1L
#define JANELA_CRITICA_MS 3

typedef struct {
    int id;
    int origem;
    long valor;
} Requisicao;

typedef struct {
    int indice;
} DadosWorker;

static volatile long *contas;
static int n_requisicoes;
static int pool_tamanho;
static int protegido;
static int atraso_ms;
static int silencioso;

static pthread_mutex_t transacao = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t fila_mutex = PTHREAD_MUTEX_INITIALIZER;
static sem_t itens_disponiveis;

static Requisicao *fila;
static int capacidade, inicio, fim, pendentes;
static int *em_atendimento;
static int concluidas;
static int retiradas;

static volatile sig_atomic_t solicitar_debug = 0;

static void tratar_debug(int sinal) {
    signal(SIGINT, tratar_debug);
    (void)sinal;
    solicitar_debug = 1;
}

static void dormir_ms(int milissegundos) {
    struct timespec t;
    if (milissegundos <= 0) return;
    t.tv_sec = milissegundos / 1000;
    t.tv_nsec = (long)(milissegundos % 1000) * 1000000L;
    while (nanosleep(&t, &t) == -1 && errno == EINTR) { }
}

static void exigir(int resultado, const char *mensagem) {
    if (resultado != 0) {
        errno = resultado;
        perror(mensagem);
        exit(EXIT_FAILURE);
    }
}

static long ler_saldo(int id) {
    return contas[id];
}

static void escrever_saldo(int id, long valor) {
    contas[id] = valor;
}

static int transferir(Requisicao r) {
    if (protegido) pthread_mutex_lock(&transacao);

    long remetente = ler_saldo(r.origem);
    if (remetente < r.valor) {
        if (protegido) pthread_mutex_unlock(&transacao);
        return 0;
    }

    escrever_saldo(r.origem, remetente - r.valor);

    long destino = ler_saldo(0);
    dormir_ms(JANELA_CRITICA_MS);
    escrever_saldo(0, destino + r.valor);

    if (protegido) pthread_mutex_unlock(&transacao);
    return 1;
}

static void adicionar(Requisicao r) {
    pthread_mutex_lock(&fila_mutex);
    if (pendentes >= capacidade) {
        fprintf(stderr, "Erro: fila cheia\n");
        exit(EXIT_FAILURE);
    }
    fila[fim] = r;
    fim = (fim + 1) % capacidade;
    pendentes++;
    pthread_mutex_unlock(&fila_mutex);
    if (sem_post(&itens_disponiveis) != 0) {
        perror("sem_post");
        exit(EXIT_FAILURE);
    }
}

static void *executar_worker(void *arg) {
    const int indice = ((DadosWorker *)arg)->indice;

    for (;;) {
        while (sem_wait(&itens_disponiveis) == -1) {
            if (errno != EINTR) {
                perror("sem_wait");
                return NULL;
            }
        }

        pthread_mutex_lock(&fila_mutex);
        Requisicao r = fila[inicio];
        inicio = (inicio + 1) % capacidade;
        pendentes--;

        if (r.id != -1) {
            retiradas++;
            em_atendimento[indice] = r.id;
            if (!silencioso) {
                printf("FCFS retirada %d -> pedido %d, worker %d\n",
                       retiradas, r.id, indice + 1);
                fflush(stdout);
            }
        }
        pthread_mutex_unlock(&fila_mutex);

        if (r.id == -1) break;
        dormir_ms(atraso_ms);
        int sucesso = transferir(r);

        pthread_mutex_lock(&fila_mutex);
        em_atendimento[indice] = 0;
        concluidas++;
        if (!silencioso) {
            printf("Concluido pedido %d pelo worker %d: %s\n",
                   r.id, indice + 1, sucesso ? "OK" : "saldo insuficiente");
            fflush(stdout);
        }
        pthread_mutex_unlock(&fila_mutex);
    }
    return NULL;
}

static void imprimir_debug(void) {
    pthread_mutex_lock(&fila_mutex);
    printf("\n===== DEBUG DA FILA (SIGINT) =====\n");
    printf("Concluidas: %d/%d | Aguardando: %d\n",
           concluidas, n_requisicoes, pendentes);
    printf("Em atendimento: ");
    int ocupadas = 0;
    for (int w = 0; w < pool_tamanho; w++) {
        if (em_atendimento[w] != 0) {
            printf("[worker %d: pedido %d] ", w + 1, em_atendimento[w]);
            ocupadas++;
        }
    }
    if (ocupadas == 0) printf("nenhum");
    printf("\nFila FCFS (do primeiro ao ultimo): ");
    if (pendentes == 0) printf("vazia");
    int limite = pendentes < 25 ? pendentes : 25;
    for (int i = 0; i < limite; i++) {
        int pos = (inicio + i) % capacidade;
        printf("%d%s", fila[pos].id, i == limite - 1 ? "" : " -> ");
    }
    if (pendentes > limite) printf(" -> ... (%d outros)", pendentes - limite);
    printf("\n==================================\n\n");
    fflush(stdout);
    pthread_mutex_unlock(&fila_mutex);
}

static int interpretar_int(const char *texto, int minimo, int maximo) {
    char *fimptr;
    errno = 0;
    long valor = strtol(texto, &fimptr, 10);
    if (errno || !texto[0] || *fimptr != '\0' || valor < minimo || valor > maximo) {
        fprintf(stderr, "Numero invalido: %s (esperado %d..%d)\n", texto, minimo, maximo);
        exit(EXIT_FAILURE);
    }
    return (int)valor;
}

int main(int argc, char **argv) {
    if (argc < 5 || argc > 6 ||
        (strcmp(argv[1], "sem") && strcmp(argv[1], "com"))) {
        fprintf(stderr, "Uso: %s sem|com N pool atraso_ms [--silencioso]\n", argv[0]);
        fprintf(stderr, "Exemplo: %s sem 20 3 400\n", argv[0]);
        return EXIT_FAILURE;
    }
    protegido = strcmp(argv[1], "com") == 0;
    n_requisicoes = interpretar_int(argv[2], 1, MAX_N);
    pool_tamanho = interpretar_int(argv[3], 1, MAX_POOL);
    atraso_ms = interpretar_int(argv[4], 0, 5000);
    silencioso = argc == 6;
    if (silencioso && strcmp(argv[5], "--silencioso") != 0) {
        fprintf(stderr, "Opcao desconhecida: %s\n", argv[5]);
        return EXIT_FAILURE;
    }
    if (pool_tamanho > n_requisicoes) pool_tamanho = n_requisicoes;

    contas = calloc((size_t)n_requisicoes + 1, sizeof(*contas));
    capacidade = n_requisicoes + pool_tamanho + 1;
    fila = calloc((size_t)capacidade, sizeof(*fila));
    em_atendimento = calloc((size_t)pool_tamanho, sizeof(*em_atendimento));
    pthread_t *workers = calloc((size_t)pool_tamanho, sizeof(*workers));
    DadosWorker *dados = calloc((size_t)pool_tamanho, sizeof(*dados));
    if (!contas || !fila || !em_atendimento || !workers || !dados) {
        perror("calloc");
        return EXIT_FAILURE;
    }
    for (int i = 1; i <= n_requisicoes; i++) contas[i] = SALDO_INICIAL;

    if (sem_init(&itens_disponiveis, 0, 0) != 0) {
        perror("sem_init");
        return EXIT_FAILURE;
    }

    if (signal(SIGINT, tratar_debug) == SIG_ERR) {
        printf("Nao foi possivel capturar o sinal\n");
        return EXIT_FAILURE;
    }

    printf("SIMULACAO PIX N:1 | pid=%ld | modo=%s | N=%d | pool=%d | atraso=%dms\n",
           (long)getpid(), protegido ? "com-protecao" : "sem-protecao",
           n_requisicoes, pool_tamanho, atraso_ms);
    printf("Debug durante a execucao: pressione Ctrl+C (SIGINT)\n");
    fflush(stdout);

    for (int w = 0; w < pool_tamanho; w++) {
        dados[w].indice = w;
        exigir(pthread_create(&workers[w], NULL, executar_worker, &dados[w]),
               "pthread_create");
    }
    for (int i = 1; i <= n_requisicoes; i++) {
        adicionar((Requisicao){ .id = i, .origem = i, .valor = VALOR_PIX });
    }

    for (;;) {
        if (solicitar_debug) {
            solicitar_debug = 0;
            imprimir_debug();
        }
        pthread_mutex_lock(&fila_mutex);
        int terminou = concluidas == n_requisicoes;
        pthread_mutex_unlock(&fila_mutex);
        if (terminou) break;
        dormir_ms(10);
    }

    for (int w = 0; w < pool_tamanho; w++) {
        adicionar((Requisicao){ .id = -1, .origem = 0, .valor = 0 });
    }
    for (int w = 0; w < pool_tamanho; w++) {
        exigir(pthread_join(workers[w], NULL), "pthread_join");
    }

    long soma = ler_saldo(0);
    for (int i = 1; i <= n_requisicoes; i++) soma += ler_saldo(i);
    long esperado = n_requisicoes * VALOR_PIX;
    long total_inicial = n_requisicoes * SALDO_INICIAL;
    printf("RESUMO modo=%s N=%d pool=%d destino_esperado=%ld destino_observado=%ld "
           "total_inicial=%ld total_final=%ld divergencia=%ld\n",
           protegido ? "com" : "sem", n_requisicoes, pool_tamanho, esperado,
           ler_saldo(0), total_inicial, soma, esperado - ler_saldo(0));
    fflush(stdout);

    sem_destroy(&itens_disponiveis);
    pthread_mutex_destroy(&transacao);
    pthread_mutex_destroy(&fila_mutex);
    free(dados);
    free(workers);
    free(em_atendimento);
    free(fila);
    free((void *)contas);
    return EXIT_SUCCESS;
}
