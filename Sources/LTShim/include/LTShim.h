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
} lt_event_kind;

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
    int error_kind;               /* matches EngineFailure kinds in Swift */
    const char* message;          /* technical detail, UTF-8 */
} lt_error_info;

/*
 * Called on an engine-owned background thread whenever something notable
 * happens. All payload pointers are only valid until the callback returns;
 * the callee must copy anything it keeps.
 */
typedef void (*lt_event_callback)(void* context, lt_event_kind kind, const void* payload, int32_t count);

lt_session* lt_session_create(lt_event_callback callback, void* context);
void lt_session_destroy(lt_session* session);

/* Returns 0 on success. On failure returns -1 and writes out_error. */
int lt_add_magnet(lt_session* session, const char* uri, const char* save_path,
                  char out_id[41], char out_error[256]);
int lt_add_torrent_data(lt_session* session, const uint8_t* data, size_t len,
                        const char* save_path, char out_id[41], char out_error[256]);

int lt_pause(lt_session* session, const char* id);
int lt_resume(lt_session* session, const char* id);
int lt_remove(lt_session* session, const char* id, int delete_files);
int lt_force_recheck(lt_session* session, const char* id);
int lt_set_file_priorities(lt_session* session, const char* id,
                           const int* priorities, int32_t count);

/* Serialised fastresume blob. Returns required size; if `cap` >= that size the
 * data is written to `buffer` and 0 is returned. */
int64_t lt_resume_data(lt_session* session, const char* id,
                       uint8_t* buffer, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* LT_SHIM_H */
