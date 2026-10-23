#include <stddef.h>
#include <stdint.h>
typedef void (*LCAoqCallback)(void *context, int kind, const void *bytes, size_t length, int value);
void *lc_aoq_create(const char *work_dir, LCAoqCallback callback, void *context);
int lc_aoq_connect(void *bridge, const void *json, size_t length);
int lc_aoq_send(void *bridge, const void *json, size_t length);
int lc_aoq_push(void *bridge, const void *pcm, size_t length, int64_t timestamp_ms);
int lc_aoq_enable(void *bridge);
void lc_aoq_close(void *bridge);
