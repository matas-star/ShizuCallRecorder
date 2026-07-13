#include "Tele2SIPBridge.h"

#include <stdint.h>
#include <baresip.h>
#include <errno.h>
#include <pthread.h>
#include <re.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_t sip_thread;
static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static struct ua *sip_ua;
static struct call *sip_call;
static crm_sip_event_handler_t event_handler;
static void *event_context;
static char *pending_account_uri;
static char *sip_registrar;
static bool thread_started;
static bool initialized;
static bool libre_initialized;
static bool conf_configured;
static bool async_initialized;
static bool baresip_initialized;
static bool ua_initialized;
static bool modules_loaded;
static bool event_registered;

static const char *config_text =
    "poll_method select\n"
    "sip_listen 0.0.0.0:0\n"
    "audio_player audiounit,default\n"
    "audio_source audiounit,default\n"
    "audio_srate 8000-48000\n"
    "audio_channels 1-2\n"
    "rtp_ports 10000-20000\n"
    "module g711.so\n"
    "module audiounit.so\n"
    "module stun.so\n"
    "module turn.so\n"
    "module ice.so\n";

static void emit(crm_sip_event_t event, const char *value)
{
    crm_sip_event_handler_t handler;
    void *context;
    pthread_mutex_lock(&state_lock);
    handler = event_handler;
    context = event_context;
    pthread_mutex_unlock(&state_lock);
    if (handler)
        handler(event, value ? value : "", context);
}

static void baresip_event(enum bevent_ev event, struct bevent *payload, void *arg)
{
    (void)arg;
    struct call *call = bevent_get_call(payload);
    switch (event) {
    case BEVENT_REGISTERING:
        emit(CRM_SIP_EVENT_REGISTERING, "");
        break;
    case BEVENT_REGISTER_OK:
        emit(CRM_SIP_EVENT_REGISTERED, "");
        break;
    case BEVENT_REGISTER_FAIL:
        emit(CRM_SIP_EVENT_REGISTRATION_FAILED, "SIP registration failed");
        break;
    case BEVENT_CALL_INCOMING:
        pthread_mutex_lock(&state_lock);
        sip_call = call;
        pthread_mutex_unlock(&state_lock);
        emit(CRM_SIP_EVENT_INCOMING, call ? call_peeruri(call) : "");
        break;
    case BEVENT_CALL_OUTGOING:
        pthread_mutex_lock(&state_lock);
        sip_call = call;
        pthread_mutex_unlock(&state_lock);
        emit(CRM_SIP_EVENT_OUTGOING, call ? call_peeruri(call) : "");
        break;
    case BEVENT_CALL_RINGING:
        emit(CRM_SIP_EVENT_RINGING, "");
        break;
    case BEVENT_CALL_ANSWERED:
    case BEVENT_CALL_ESTABLISHED:
        emit(CRM_SIP_EVENT_ACTIVE, "");
        break;
    case BEVENT_CALL_CLOSED:
        pthread_mutex_lock(&state_lock);
        sip_call = NULL;
        pthread_mutex_unlock(&state_lock);
        emit(CRM_SIP_EVENT_ENDED, "");
        break;
    case BEVENT_AUDIO_ERROR:
        emit(CRM_SIP_EVENT_ERROR, "SIP audio error");
        break;
    default:
        break;
    }
}

static void cleanup(void)
{
    if (event_registered) {
        bevent_unregister(baresip_event);
        event_registered = false;
    }
    if (ua_initialized) {
        ua_stop_all(true);
        ua_close();
        ua_initialized = false;
    }
    if (modules_loaded) {
        module_app_unload();
        modules_loaded = false;
    }
    if (conf_configured) {
        conf_close();
        conf_configured = false;
    }
    if (baresip_initialized) {
        baresip_close();
        baresip_initialized = false;
    }
    if (async_initialized) {
        re_thread_async_close();
        async_initialized = false;
    }
    if (libre_initialized) {
        mod_close();
        libre_close();
        libre_initialized = false;
    }
    initialized = false;
    sip_ua = NULL;
    sip_call = NULL;
}

static void *run_sip(void *arg)
{
    (void)arg;
    int error = libre_init();
    libre_initialized = !error;
    if (!error)
        error = conf_configure_buf((const uint8_t *)config_text, strlen(config_text));
    conf_configured = !error;
    if (!error)
        error = re_thread_async_init(2);
    async_initialized = !error;
    if (!error)
        error = baresip_init(conf_config());
    baresip_initialized = !error;
    if (!error)
        error = ua_init("CRM Phone iOS", true, true, true);
    ua_initialized = !error;
    if (!error)
        error = conf_modules();
    modules_loaded = !error;
    if (!error)
        error = bevent_register(baresip_event, NULL);
    event_registered = !error;
    if (!error)
        error = ua_alloc(&sip_ua, pending_account_uri);
    if (error) {
        char message[64];
        snprintf(message, sizeof(message), "SIP initialization failed: %d", error);
        emit(CRM_SIP_EVENT_ERROR, message);
        cleanup();
        return NULL;
    }
    initialized = true;
    error = re_main(NULL);
    if (error)
        emit(CRM_SIP_EVENT_ERROR, "SIP event loop failed");
    cleanup();
    return NULL;
}

int crm_sip_start(const char *account_uri,
                  const char *registrar,
                  crm_sip_event_handler_t handler,
                  void *context)
{
    if (!account_uri || !registrar || !handler)
        return EINVAL;
    pthread_mutex_lock(&state_lock);
    if (thread_started) {
        pthread_mutex_unlock(&state_lock);
        return EALREADY;
    }
    pending_account_uri = strdup(account_uri);
    sip_registrar = strdup(registrar);
    event_handler = handler;
    event_context = context;
    if (!pending_account_uri || !sip_registrar) {
        free(pending_account_uri);
        free(sip_registrar);
        pending_account_uri = NULL;
        sip_registrar = NULL;
        pthread_mutex_unlock(&state_lock);
        return ENOMEM;
    }
    thread_started = true;
    pthread_mutex_unlock(&state_lock);
    int error = pthread_create(&sip_thread, NULL, run_sip, NULL);
    if (error) {
        pthread_mutex_lock(&state_lock);
        thread_started = false;
        pthread_mutex_unlock(&state_lock);
    }
    return error;
}

void crm_sip_stop(void)
{
    pthread_mutex_lock(&state_lock);
    bool should_join = thread_started;
    pthread_mutex_unlock(&state_lock);
    if (!should_join)
        return;
    re_cancel();
    pthread_join(sip_thread, NULL);
    pthread_mutex_lock(&state_lock);
    thread_started = false;
    event_handler = NULL;
    event_context = NULL;
    free(pending_account_uri);
    free(sip_registrar);
    pending_account_uri = NULL;
    sip_registrar = NULL;
    pthread_mutex_unlock(&state_lock);
}

int crm_sip_call(const char *phone_number)
{
    if (!phone_number || !initialized || !sip_ua || !sip_registrar)
        return ENOTCONN;
    char destination[512];
    int count = snprintf(destination, sizeof(destination), "sip:%s@%s",
                         phone_number, sip_registrar);
    if (count < 0 || (size_t)count >= sizeof(destination))
        return ENAMETOOLONG;
    re_thread_enter();
    int error = ua_connect(sip_ua, &sip_call, NULL, destination, VIDMODE_OFF);
    re_thread_leave();
    return error;
}

int crm_sip_answer(void)
{
    if (!initialized || !sip_ua || !sip_call)
        return ENOENT;
    re_thread_enter();
    int error = ua_answer(sip_ua, sip_call, VIDMODE_OFF);
    re_thread_leave();
    return error;
}

void crm_sip_end(void)
{
    if (!initialized || !sip_ua || !sip_call)
        return;
    re_thread_enter();
    ua_hangup(sip_ua, sip_call, 0, NULL);
    re_thread_leave();
}

int crm_sip_set_muted(bool muted)
{
    if (!initialized || !sip_call)
        return ENOENT;
    re_thread_enter();
    struct audio *audio = call_audio(sip_call);
    if (!audio) {
        re_thread_leave();
        return ENOENT;
    }
    audio_mute(audio, muted);
    re_thread_leave();
    return 0;
}

int crm_sip_set_held(bool held)
{
    if (!initialized || !sip_call)
        return ENOENT;
    re_thread_enter();
    int error = call_hold(sip_call, held);
    re_thread_leave();
    return error;
}

int crm_sip_send_dtmf(char digit)
{
    if (!initialized || !sip_call)
        return ENOENT;
    re_thread_enter();
    int error = call_send_digit(sip_call, digit);
    re_thread_leave();
    return error;
}

bool crm_sip_is_registered(void)
{
    return initialized && sip_ua && ua_isregistered(sip_ua);
}
