#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <event2/event.h>
#include <event2/buffer.h>
#include <event2/bufferevent.h>
#include <event2/listener.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#define MAX_HEADER 16384
#define SSH_HOST "127.0.0.1"

/* Puerto SSH local: se recibe como argumento y es la única fuente del valor. */
static int ssh_port;
static char allowed_ip[32];
static char allowed_name[32];

static const char RESPONSE[] =
    "HTTP/1.1 101 <strong>@lacasitamx</strong>\r\n\r\n"
    "HTTP/1.1 101 Conexion Exitosa\r\n\r\n";

typedef struct {
    struct bufferevent *client;
    struct bufferevent *upstream;
    int relaying;
    int closing;
    int closed;
} Conn;

static void close_conn(Conn *c)
{
    if (!c || c->closed) return;
    c->closed = 1;

    struct bufferevent *a = c->client;
    struct bufferevent *b = c->upstream;
    c->client = NULL;
    c->upstream = NULL;

    if (a) bufferevent_free(a);
    if (b) bufferevent_free(b);
    free(c);
}

static void reject_conn(Conn *c, const char *status)
{
    if (!c || c->closed || !c->client) return;

    c->closing = 1;
    bufferevent_disable(c->client, EV_READ);
    if (c->upstream) {
        bufferevent_free(c->upstream);
        c->upstream = NULL;
    }

    bufferevent_write(c->client, status, strlen(status));
}

static int valid_host(char *headers)
{
    char *save = NULL;
    char *line = strtok_r(headers, "\r\n", &save);

    while (line) {
        char *colon = strchr(line, ':');
        if (colon) {
            *colon = '\0';

            if (strcasecmp(line, "X-Real-Host") == 0) {
                char *v = colon + 1;
                while (*v && isspace((unsigned char)*v)) v++;

                char *end = v + strlen(v);
                while (end > v && isspace((unsigned char)end[-1]))
                    *--end = '\0';

                return !strcasecmp(v, allowed_ip) ||
                       !strcasecmp(v, allowed_name);
            }
        }
        line = strtok_r(NULL, "\r\n", &save);
    }

    return 1;
}

static void read_cb(struct bufferevent *bev, void *arg)
{
    Conn *c = arg;
    if (!c || c->closed) return;

    struct evbuffer *in = bufferevent_get_input(bev);

    if (c->relaying) {
        struct bufferevent *dst =
            (bev == c->client) ? c->upstream : c->client;

        if (dst)
            evbuffer_add_buffer(bufferevent_get_output(dst), in);
        return;
    }

    size_t n = evbuffer_get_length(in);

    if (n >= MAX_HEADER) {
        reject_conn(c,
            "HTTP/1.1 431 Request Header Fields Too Large\r\n"
            "Connection: close\r\n\r\n");
        return;
    }

    unsigned char *data = evbuffer_pullup(in, -1);
    if (!data) return;

    if (!memmem(data, n, "\r\n\r\n", 4))
        return;

    char *headers = malloc(n + 1);
    if (!headers) {
        close_conn(c);
        return;
    }

    memcpy(headers, data, n);
    headers[n] = '\0';

    int allowed = valid_host(headers);
    free(headers);
    evbuffer_drain(in, n);

    if (!allowed) {
        reject_conn(c,
            "HTTP/1.1 403 Forbidden\r\n"
            "Connection: close\r\n\r\n");
        return;
    }

    bufferevent_disable(c->client, EV_READ);

    struct event_base *base = bufferevent_get_base(c->client);
    c->upstream = bufferevent_socket_new(
        base, -1, BEV_OPT_CLOSE_ON_FREE | BEV_OPT_DEFER_CALLBACKS);

    if (!c->upstream) {
        close_conn(c);
        return;
    }

    extern void upstream_event_cb(struct bufferevent *, short, void *);
    bufferevent_setcb(c->upstream, read_cb, NULL,
                      upstream_event_cb, c);

    struct timeval tv = {60, 0};
    bufferevent_set_timeouts(c->upstream, &tv, NULL);
    bufferevent_setwatermark(c->upstream, EV_READ, 0, 262144);
    bufferevent_enable(c->upstream, EV_READ | EV_WRITE);

    if (bufferevent_socket_connect_hostname(
            c->upstream, NULL, AF_INET, SSH_HOST, ssh_port) < 0) {
        close_conn(c);
    }
}

static void write_cb(struct bufferevent *bev, void *arg)
{
    Conn *c = arg;
    if (!c || c->closed) return;

    if (c->closing &&
        evbuffer_get_length(bufferevent_get_output(bev)) == 0) {
        close_conn(c);
    }
}

void upstream_event_cb(struct bufferevent *bev, short events, void *arg)
{
    (void)bev;
    Conn *c = arg;
    if (!c || c->closed) return;

    if (events & BEV_EVENT_CONNECTED) {
        c->relaying = 1;
        bufferevent_setcb(c->client, read_cb, write_cb, NULL, c);
        bufferevent_setcb(c->upstream, read_cb, write_cb,
                          upstream_event_cb, c);

        bufferevent_write(c->client, RESPONSE, sizeof(RESPONSE) - 1);

        struct timeval tv = {60, 0};
        bufferevent_set_timeouts(c->client, &tv, NULL);
        bufferevent_set_timeouts(c->upstream, &tv, NULL);

        bufferevent_setwatermark(c->client, EV_READ, 0, 262144);
        bufferevent_setwatermark(c->upstream, EV_READ, 0, 262144);

        bufferevent_enable(c->client, EV_READ | EV_WRITE);
        bufferevent_enable(c->upstream, EV_READ | EV_WRITE);
        return;
    }

    if (events & (BEV_EVENT_EOF | BEV_EVENT_ERROR | BEV_EVENT_TIMEOUT))
        close_conn(c);
}

static void accept_cb(struct evconnlistener *listener, evutil_socket_t fd,
                      struct sockaddr *addr, int socklen, void *arg)
{
    (void)listener;
    (void)addr;
    (void)socklen;

    struct event_base *base = arg;
    evutil_make_socket_nonblocking(fd);

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    Conn *c = calloc(1, sizeof(*c));
    if (!c) {
        close(fd);
        return;
    }

    c->client = bufferevent_socket_new(
        base, fd, BEV_OPT_CLOSE_ON_FREE | BEV_OPT_DEFER_CALLBACKS);

    if (!c->client) {
        close(fd);
        free(c);
        return;
    }

    extern void client_event_cb(struct bufferevent *, short, void *);
    bufferevent_setcb(c->client, read_cb, write_cb, client_event_cb, c);

    struct timeval tv = {60, 0};
    bufferevent_set_timeouts(c->client, &tv, NULL);
    bufferevent_setwatermark(c->client, EV_READ, 0, MAX_HEADER);
    bufferevent_enable(c->client, EV_READ | EV_WRITE);
}

void client_event_cb(struct bufferevent *bev, short events, void *arg)
{
    (void)bev;
    Conn *c = arg;
    if (!c || c->closed) return;

    if (events & (BEV_EVENT_EOF | BEV_EVENT_ERROR | BEV_EVENT_TIMEOUT))
        close_conn(c);
}

static void listener_error_cb(struct evconnlistener *listener, void *arg)
{
    (void)listener;
    struct event_base *base = arg;
    perror("PDirect: error del listener");
    event_base_loopexit(base, NULL);
}

int main(int argc, char **argv)
{
    char *end = NULL;
    long port = argc == 2 ? strtol(argv[1], &end, 10) : 0;

    if (argc != 2 || end == argv[1] || *end != '\0' ||
        port < 1 || port > 65535) {
        fprintf(stderr, "Uso: %s PUERTO_SSH (1-65535)\n", argv[0]);
        return 2;
    }

    ssh_port = (int)port;
    snprintf(allowed_ip, sizeof(allowed_ip), "%s:%d", SSH_HOST, ssh_port);
    snprintf(allowed_name, sizeof(allowed_name), "localhost:%d", ssh_port);

    signal(SIGPIPE, SIG_IGN);

    struct event_base *base = event_base_new();
    if (!base) {
        fprintf(stderr, "No se pudo crear event_base\n");
        return 1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(80);

    struct evconnlistener *listener = evconnlistener_new_bind(
        base, accept_cb, base,
        LEV_OPT_CLOSE_ON_FREE | LEV_OPT_REUSEABLE,
        1024, (struct sockaddr *)&addr, sizeof(addr));

    if (!listener) {
        perror("No se pudo abrir el puerto 80");
        event_base_free(base);
        return 1;
    }

    evconnlistener_set_error_cb(listener, listener_error_cb);
    fprintf(stderr, "PDirect-C escuchando en 0.0.0.0:80; SSH local %s:%d\n",
            SSH_HOST, ssh_port);

    event_base_dispatch(base);

    evconnlistener_free(listener);
    event_base_free(base);
    return 0;
}
