#ifndef CRM_PHONE_TELE2_SIP_BRIDGE_H
#define CRM_PHONE_TELE2_SIP_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    CRM_SIP_EVENT_REGISTERING = 0,
    CRM_SIP_EVENT_REGISTERED,
    CRM_SIP_EVENT_REGISTRATION_FAILED,
    CRM_SIP_EVENT_INCOMING,
    CRM_SIP_EVENT_OUTGOING,
    CRM_SIP_EVENT_RINGING,
    CRM_SIP_EVENT_ACTIVE,
    CRM_SIP_EVENT_ENDED,
    CRM_SIP_EVENT_ERROR
} crm_sip_event_t;

typedef void (*crm_sip_event_handler_t)(crm_sip_event_t event,
                                         const char *value,
                                         void *context);

int crm_sip_start(const char *account_uri,
                  const char *registrar,
                  crm_sip_event_handler_t handler,
                  void *context);
void crm_sip_stop(void);
int crm_sip_call(const char *phone_number);
int crm_sip_answer(void);
void crm_sip_end(void);
int crm_sip_set_muted(bool muted);
int crm_sip_set_held(bool held);
int crm_sip_send_dtmf(char digit);
bool crm_sip_is_registered(void);

#ifdef __cplusplus
}
#endif

#endif
