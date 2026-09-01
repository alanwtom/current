#include "LTShim.h"

#include <libtorrent/session.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <span>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

using namespace lt;

namespace {

// kErrorKind* values must stay aligned with LT_ERROR_* in LTShim.h.

struct SessionContext {
    lt_event_callback callback = nullptr;
    void* user = nullptr;
    std::unique_ptr<session> ses;
    std::thread worker;
    std::atomic<bool> running{false};
    std::chrono::steady_clock::time_point next_stats_tick{std::chrono::steady_clock::now()};
};

inline void copy_string(char* dst, size_t cap, char const* src) {
    std::snprintf(dst, cap, "%s", src ? src : "");
}

std::string hex_id(torrent_handle const& h) {
    static char const* digits = "0123456789abcdef";
    // v1 is all-zero for v2-only torrents; fall back to the first 20 bytes of
    // the v2 hash (the standard truncated-v2 identity) so every torrent gets
    // a unique, stable id.
    info_hash_t const& hashes = h.info_hashes();
    unsigned char const* bytes = hashes.has_v1()
        ? reinterpret_cast<unsigned char const*>(hashes.v1.data())
        : reinterpret_cast<unsigned char const*>(hashes.v2.data());
    std::string out;
    out.reserve(40);
    for (int i = 0; i < 20; ++i) {
        out.push_back(digits[(bytes[i] >> 4) & 0xF]);
        out.push_back(digits[bytes[i] & 0xF]);
    }
    return out;
}

int classify_error(error_code const& ec) {
    if (ec == errors::duplicate_torrent) return LT_ERROR_DUPLICATE;
    if (ec == errors::file_collision) return LT_ERROR_FILE_CONFLICT;
    if (ec == errors::no_metadata) return LT_ERROR_METADATA_TIMEOUT;
    if (ec.category() == boost::system::generic_category()
        && ec.value() == int(std::errc::no_space_on_device)) return LT_ERROR_DISK_FULL;
    return LT_ERROR_UNKNOWN;
}

int map_state(torrent_status const& st) {
    if (st.flags & torrent_flags::paused) return LT_STATE_PAUSED;
    switch (st.state) {
        case torrent_status::downloading_metadata: return LT_STATE_RESOLVING;
        case torrent_status::checking_files:
        case torrent_status::checking_resume_data: return LT_STATE_CHECKING;
        case torrent_status::downloading: return LT_STATE_DOWNLOADING;
        case torrent_status::finished:
        case torrent_status::seeding: return LT_STATE_SEEDING;
        default: return LT_STATE_QUEUED;
    }
}

void dispatch_error(SessionContext* ctx, torrent_handle const& h,
                    std::string const& message, error_code const& ec) {
    std::string id = hex_id(h);
    lt_error_info info{};
    info.id = id.c_str();
    info.error_kind = classify_error(ec);
    info.message = message.c_str();
    if (ctx->callback) ctx->callback(ctx->user, LT_EVENT_ERROR, &info, 1);
}

bool find_handle(SessionContext* ctx, char const* id, torrent_handle* out) {
    for (auto const& h : ctx->ses->get_torrents()) {
        if (hex_id(h) == id) {
            *out = h;
            return true;
        }
    }
    return false;
}

} // namespace

extern "C" {

lt_session* lt_session_create(lt_event_callback callback, void* context) {
    auto* ctx = new SessionContext();
    ctx->callback = callback;
    ctx->user = context;

    settings_pack pack;
    pack.set_int(settings_pack::alert_mask,
                 alert_category::status | alert_category::error | alert_category::storage);
    pack.set_str(settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");
    pack.set_bool(settings_pack::enable_upnp, true);
    pack.set_bool(settings_pack::enable_natpmp, true);
    pack.set_bool(settings_pack::enable_lsd, true);
    pack.set_int(settings_pack::connections_limit, 240);
    pack.set_int(settings_pack::alert_queue_size, 5000);
    pack.set_str(settings_pack::user_agent, "Current/1.0");

    try {
        session_params params;
        params.settings = pack;
        ctx->ses = std::make_unique<session>(params);
    } catch (...) {
        delete ctx;
        return nullptr;
    }

    ctx->running = true;
    ctx->worker = std::thread([ctx]() {
        while (ctx->running) {
            ctx->ses->wait_for_alert(std::chrono::milliseconds(250));
            std::vector<alert*> alerts;
            ctx->ses->pop_alerts(&alerts);

            for (alert const* a : alerts) {
                if (auto const* meta = alert_cast<metadata_received_alert>(a)) {
                    torrent_handle h = meta->handle;
                    std::shared_ptr<const torrent_info> ti = h.torrent_file();
                    if (!ti) continue;

                    file_storage const& fs = ti->files();
                    int32_t count = static_cast<int32_t>(fs.num_files());

                    // Locals below outlive emit(); pointers handed to Swift
                    // are valid only for the duration of the callback.
                    std::string id = hex_id(h);
                    std::string name = ti->name();
                    std::string joined_paths;
                    std::vector<uint64_t> sizes;
                    sizes.reserve(static_cast<size_t>(count));
                    for (file_index_t i{0}; i != fs.end_file(); ++i) {
                        if (!joined_paths.empty()) joined_paths.push_back('\n');
                        joined_paths.append(fs.file_path(i));
                        sizes.push_back(static_cast<uint64_t>(fs.file_size(i)));
                    }

                    lt_metadata_info info{};
                    info.id = id.c_str();
                    info.name = name.c_str();
                    info.total_size = static_cast<uint64_t>(ti->total_size());
                    info.piece_count = static_cast<int32_t>(ti->num_pieces());
                    info.piece_length = static_cast<int32_t>(ti->piece_length());
                    info.file_count = count;
                    info.file_paths = joined_paths.c_str();
                    info.file_sizes = sizes.data();
                    if (ctx->callback) ctx->callback(ctx->user, LT_EVENT_METADATA, &info, 1);
                } else if (auto const* done = alert_cast<torrent_finished_alert>(a)) {
                    std::string id = hex_id(done->handle);
                    if (ctx->callback) ctx->callback(ctx->user, LT_EVENT_COMPLETED, id.c_str(), 1);
                } else if (auto const* err = alert_cast<torrent_error_alert>(a)) {
                    dispatch_error(ctx, err->handle, err->message(), err->error);
                } else if (auto const* srd = alert_cast<save_resume_data_alert>(a)) {
                    std::string id = hex_id(srd->handle);
                    auto buf = write_resume_data_buf(srd->params);
                    lt_resume_data_info info{};
                    info.id = id.c_str();
                    info.size = static_cast<int64_t>(buf.size());
                    info.data = reinterpret_cast<uint8_t const*>(buf.data());
                    if (ctx->callback) ctx->callback(ctx->user, LT_EVENT_RESUME_DATA, &info, 1);
                } else if (auto const* srdf = alert_cast<save_resume_data_failed_alert>(a)) {
                    std::string id = hex_id(srdf->handle);
                    lt_resume_data_info info{};
                    info.id = id.c_str();
                    info.size = 0;
                    info.data = nullptr;
                    if (ctx->callback) ctx->callback(ctx->user, LT_EVENT_RESUME_DATA, &info, 1);
                } else if (auto const* removed = alert_cast<torrent_removed_alert>(a)) {
                    std::string id = hex_id(removed->handle);
                    if (ctx->callback)
                        ctx->callback(ctx->user, LT_EVENT_REMOVED, id.c_str(), 1);
                }
            }

            auto const now = std::chrono::steady_clock::now();
            if (!ctx->running || now < ctx->next_stats_tick) continue;
            ctx->next_stats_tick = now + std::chrono::milliseconds(1000);

            std::vector<torrent_handle> torrents = ctx->ses->get_torrents();
            if (torrents.empty()) continue;

            std::vector<lt_stats_row> rows;
            rows.reserve(torrents.size());
            std::vector<std::string> ids;
            ids.reserve(torrents.size());

            for (auto const& h : torrents) {
                torrent_status st = h.status();
                ids.push_back(hex_id(h));

                lt_stats_row row{};
                row.id = ids.back().c_str();
                row.state = map_state(st);
                row.progress = static_cast<double>(st.progress_ppm) / 1000000.0;
                row.total_wanted = static_cast<uint64_t>(st.total_wanted);
                row.total_downloaded = static_cast<uint64_t>(st.total_payload_download);
                row.total_uploaded = static_cast<uint64_t>(st.total_payload_upload);
                row.download_rate = st.download_payload_rate;
                row.upload_rate = st.upload_payload_rate;
                row.connected_seeds = st.num_seeds;
                row.connected_peers = st.num_peers;
                row.known_seeds = st.list_seeds > st.num_seeds ? st.list_seeds : st.num_seeds;
                row.seed_seconds = static_cast<uint64_t>(st.seeding_duration.count());
                row.active_seconds = static_cast<uint64_t>(st.active_duration.count());
                row.has_metadata = st.has_metadata ? 1 : 0;
                rows.push_back(row);
            }

            lt_stats_batch batch{rows.data(), static_cast<int32_t>(rows.size())};
            if (ctx->callback) ctx->callback(ctx->user, LT_EVENT_STATS, &batch, 1);
        }
    });

    return reinterpret_cast<lt_session*>(ctx);
}

void lt_session_destroy(lt_session* opaque) {
    auto* ctx = reinterpret_cast<SessionContext*>(opaque);
    if (!ctx) return;
    ctx->running = false;
    if (ctx->worker.joinable()) ctx->worker.join();
    ctx->ses.reset();
    delete ctx;
}

int lt_add_magnet(lt_session* opaque, const char* uri, const char* save_path,
                  char out_id[41], char out_error[256], int* out_error_kind) {
    auto* ctx = reinterpret_cast<SessionContext*>(opaque);
    if (!ctx || !ctx->ses) return -1;
    try {
        error_code ec;
        add_torrent_params atp;
        parse_magnet_uri(uri, atp, ec);
        if (ec) {
            copy_string(out_error, 256, ec.message().c_str());
            if (out_error_kind) *out_error_kind = classify_error(ec);
            return -1;
        }
        atp.save_path = save_path;
        torrent_handle h = ctx->ses->add_torrent(atp);
        copy_string(out_id, 41, hex_id(h).c_str());
        return 0;
    } catch (system_error const& e) {
        copy_string(out_error, 256, e.code().message().c_str());
        if (out_error_kind) *out_error_kind = classify_error(e.code());
        return -1;
    } catch (...) {
        copy_string(out_error, 256, "Unknown engine error");
        if (out_error_kind) *out_error_kind = LT_ERROR_UNKNOWN;
        return -1;
    }
}

int lt_add_torrent_data(lt_session* opaque, const uint8_t* data, size_t len,
                        const char* save_path, char out_id[41], char out_error[256],
                        int* out_error_kind) {
    auto* ctx = reinterpret_cast<SessionContext*>(opaque);
    if (!ctx || !ctx->ses) return -1;
    try {
        add_torrent_params atp = load_torrent_buffer(
            std::span<char const>(reinterpret_cast<char const*>(data),
                                  static_cast<size_t>(len)));
        atp.save_path = save_path;
        torrent_handle h = ctx->ses->add_torrent(atp);
        copy_string(out_id, 41, hex_id(h).c_str());
        return 0;
    } catch (system_error const& e) {
        copy_string(out_error, 256, e.code().message().c_str());
        if (out_error_kind) *out_error_kind = classify_error(e.code());
        return -1;
    } catch (...) {
        copy_string(out_error, 256, "Unknown engine error");
        if (out_error_kind) *out_error_kind = LT_ERROR_UNKNOWN;
        return -1;
    }
}

int lt_pause(lt_session* opaque, const char* id) {
    auto* ctx = reinterpret_cast<SessionContext*>(opaque);
    if (!ctx || !ctx->ses) return -1;
    torrent_handle h;
    if (!find_handle(ctx, id, &h)) return -1;
    h.unset_flags(torrent_flags::auto_managed);
    h.pause(torrent_handle::graceful_pause);
    return 0;
}

int lt_resume(lt_session* opaque, const char* id) {
    auto* ctx = reinterpret_cast<SessionContext*>(opaque);
    if (!ctx || !ctx->ses) return -1;
    torrent_handle h;
    if (!find_handle(ctx, id, &h)) return -1;
    h.set_flags(torrent_flags::auto_managed);
    h.resume();
    return 0;
}

int lt_remove(lt_session* opaque, const char* id, int delete_files) {
    auto* ctx = reinterpret_cast<SessionContext*>(opaque);
    if (!ctx || !ctx->ses) return -1;
    torrent_handle h;
    if (!find_handle(ctx, id, &h)) return -1;
    remove_flags_t flags = {};
    if (delete_files) flags |= session::delete_files;
    ctx->ses->remove_torrent(h, flags);
    return 0;
}

int lt_force_recheck(lt_session* opaque, const char* id) {
    auto* ctx = reinterpret_cast<SessionContext*>(opaque);
    if (!ctx || !ctx->ses) return -1;
    torrent_handle h;
    if (!find_handle(ctx, id, &h)) return -1;
    h.force_recheck();
    return 0;
}

int lt_set_file_priorities(lt_session* opaque, const char* id,
                           const int* priorities, int32_t count) {
    auto* ctx = reinterpret_cast<SessionContext*>(opaque);
    if (!ctx || !ctx->ses) return -1;
    torrent_handle h;
    if (!find_handle(ctx, id, &h)) return -1;
    std::vector<download_priority_t> prio;
    prio.reserve(count > 0 ? count : 0);
    for (int32_t i = 0; i < count; ++i) {
        prio.push_back(download_priority_t(static_cast<std::uint8_t>(priorities[i])));
    }
    h.prioritize_files(prio);
    return 0;
}

int lt_request_resume_data(lt_session* opaque, const char* id) {
    auto* ctx = reinterpret_cast<SessionContext*>(opaque);
    if (!ctx || !ctx->ses) return -1;
    torrent_handle h;
    if (!find_handle(ctx, id, &h)) return -1;
    h.save_resume_data();
    return 0;
}

} // extern "C"
