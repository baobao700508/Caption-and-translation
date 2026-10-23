#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*LCRTCEvent)(void *, int, const void *, size_t, int);
void *lc_rtc_create(LCRTCEvent callback, void *context);
void lc_rtc_answer(void *, const void *, size_t);
int lc_rtc_send(void *, const void *, size_t);
int lc_rtc_push(void *, const void *, size_t);
int lc_rtc_pending(void *);
void lc_rtc_finish_input(void *);
void lc_rtc_report(void *);
void lc_rtc_close(void *);
#ifdef __cplusplus
}
#endif
