#ifndef LT_SHIM_H
#define LT_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lt_session lt_session;

typedef enum {
    LT_EVENT_STATS = 0,
    LT_EVENT_METADATA = 1,
    LT_EVENT_COMPLETED = 2,
    LT_EVENT_ERROR = 3,
    LT_EVENT_REMOVED = 4,
    LT_EVENT_RESUME_DATA = 5,
} lt_event_kind;

/* Values for lt_error_info.error_kind, matching EngineFailure.Kind in Swift. */
enum {
    LT_ERROR_SAVE_PATH = 1,
    LT_ERROR_DISK_FULL = 2,
    LT_ERROR_NETWORK = 3,
    LT_ERROR_METADATA_TIMEOUT = 4,
    LT_ERROR_DUPLICATE = 5,
    LT_ERROR_CORRUPTED = 6,
    LT_ERROR_FILE_CONFLICT = 7,
    LT_ERROR_SHUTDOWN = 8,
    LT_ERROR_UNKNOWN = 9,
};

/// State codes mirrored from torrent_status::state_t plus pause/error overlays.
enum {
    LT_STATE_QUEUED = 0,
    LT_STATE_RESOLVING = 1,
    LT_STATE_DOWNLOADING = 2,
    LT_STATE_SEEDING = 3,
    LT_STATE_PAUSED = 4,
    LT_STATE_CHECKING = 5,
    LT_STATE_FAILED = 6,
};

typedef struct {
    const char* id;               /* 40-char hex info-hash, valid during callback */
    int state;
    double progress;              /* 0..1 */
    uint64_t total_wanted;
    uint64_t total_downloaded;    /* payload bytes, all-time */
    uint64_t total_uploaded;      /* payload bytes, all-time */
    double download_rate;         /* bytes/s */
    double upload_rate;           /* bytes/s */
    int connected_seeds;
    int connected_peers;
    int known_seeds;
    uint64_t seed_seconds;        /* time spent seeding, persisted */
    uint64_t active_seconds;      /* any activity, persisted */
    int has_metadata;
} lt_stats_row;

/// Payload for LT_EVENT_STATS: array of `count` rows.
typedef struct {
    const lt_stats_row* rows;
    int32_t count;
} lt_stats_batch;

typedef struct {
    const char* id;
    const char* name;
    uint64_t total_size;
    int32_t piece_count;
    int32_t piece_length;
    int32_t file_count;
    /* Parallel arrays of length file_count. Paths joined with '\n'. */
    const char* file_paths;
    const uint64_t* file_sizes;
} lt_metadata_info;

typedef struct {
    const char* id;
    int error_kind;               /* LT_ERROR_* constant */
    const char* message;          /* technical detail, UTF-8 */
} lt_error_info;

/* Payload for LT_EVENT_RESUME_DATA: the serialised fastresume blob for one
 * torrent, delivered on the worker thread after lt_request_resume_data.
 * size == 0 means the request failed. */
typedef struct {
    const char* id;
    const uint8_t* data;          /* valid during callback */
    int64_t size;
} lt_resume_data_info;

/*
 * Called on an engine-owned background thread whenever something notable
 * happens. All payload pointers are only valid until the callback returns;
 * the callee must copy anything it keeps.
 */
typedef void (*lt_event_callback)(void* context, lt_event_kind kind, const void* payload, int32_t count);

/*
 * `state_path` is where the DHT routing table is kept between launches; pass
 * NULL or "" to disable it. It is written on a timer as well as at shutdown,
 * because a clean shutdown is not guaranteed.
 */
lt_session* lt_session_create(lt_event_callback callback, void* context,
                              const char* state_path);
void lt_session_destroy(lt_session* session);

/* Returns 0 on success. On failure returns -1, writes out_error and sets
 * *out_error_kind to an LT_ERROR_* constant. */
int lt_add_magnet(lt_session* session, const char* uri, const char* save_path,
                  char out_id[41], char out_error[256], int* out_error_kind);
int lt_add_torrent_data(lt_session* session, const uint8_t* data, size_t len,
                        const char* save_path, char out_id[41], char out_error[256],
                        int* out_error_kind);

int lt_pause(lt_session* session, const char* id);
int lt_resume(lt_session* session, const char* id);
int lt_remove(lt_session* session, const char* id, int delete_files);
/* Changes where a torrent's files go. Meant for a torrent that has resolved but
 * not started, which is when the app asks the user where to put it. */
int lt_set_save_path(lt_session* session, const char* id, const char* save_path);
int lt_force_recheck(lt_session* session, const char* id);
int lt_set_file_priorities(lt_session* session, const char* id,
                           const int* priorities, int32_t count);

/* Session-wide settings, applied together.
 *
 * Rates are bytes/second where 0 means unlimited — libtorrent's own
 * convention, kept rather than translated so nothing can mix up nil and zero
 * at the boundary. listen_port 0 asks the OS for any free port.
 * encryption_policy: 0 = allow both, 1 = prefer encrypted, 2 = require it. */
typedef struct {
    int download_rate;
    int upload_rate;
    int max_connections;
    int max_upload_slots;
    int active_downloads;
    int active_seeds;
    int listen_port;
    int enable_dht;
    int enable_lsd;
    int enable_port_mapping;
    int encryption_policy;
} lt_settings;

/* Returns 0 on success, -1 if the session is gone. */
int lt_apply_settings(lt_session* session, const lt_settings* settings);

/* Non-blocking: asks the torrent to generate resume data. The result is
 * delivered later as an LT_EVENT_RESUME_DATA callback on the worker thread.
 * Returns 0 if the request was made, -1 if the torrent is unknown. */
int lt_request_resume_data(lt_session* session, const char* id);

#ifdef __cplusplus
}
#endif

#endif /* LT_SHIM_H */
