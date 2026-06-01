// vkcapture-consumer — consume the obs-vkcapture Vulkan layer and encode to mp4.
//
// Captures cs2's frames inside its Vulkan present instead of reading them back
// through the X server (which serialized with cs2's render and stalled it). The
// obs-vkcapture LAYER (loaded into cs2 via OBS_VKCAPTURE=1) hooks
// vkQueuePresentKHR, copies the swapchain image into a shared host-visible dmabuf,
// and offers it over a unix socket. This program binds that socket, mmaps the
// shared image, and feeds frames into our GStreamer NVENC pipeline — nothing
// touches the X server, so it can't stall cs2's render.
//
// PROTOCOL (vendored in capture.h, from nowrep/obs-vkcapture, GPLv2):
//   - We are the SERVER: bind abstract socket "\0/com/obsproject/vkcapture",
//     listen()/accept4(). The layer is the client and retries connect() every 1s,
//     so starting this consumer per-segment (after cs2 is up) is fine.
//   - On connect the layer sends capture_client_data{exe}; we reply with
//     capture_control_data{capturing=1, linear, map_host} to make it start.
//   - It then sends capture_texture_data{w,h,fourcc,strides,offsets,flip} + the
//     dmabuf fd via SCM_RIGHTS, ONCE per swapchain (not per frame). We mmap it and
//     sample asynchronously on a fps timer.
//
// USAGE:
//   vkcapture-consumer '<gstreamer pipeline with appsrc name=vksrc>'
//     Feeds cs2 frames into the appsrc named "vksrc"; finalizes the mp4 on SIGINT
//     (clean whole-pipeline EOS — same contract as stop_clip_capture).
//   VKCAP_TEST=1 vkcapture-consumer
//     Debug: no encode — logs each frame's geometry (fourcc/modifier/nfd), dumps
//     one raw frame to $VKCAP_TEST_DUMP (default /tmp/vkcap-frame.raw), and exits
//     after VKCAP_TEST_SECS (default 15s). Run with cs2 up under OBS_VKCAPTURE=1.

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <stdbool.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <glib.h>
#include <glib-unix.h>
#include <gst/gst.h>
#include <gst/app/gstappsrc.h>

#include "capture.h"

static const char SOCK_NAME[] = "/com/obsproject/vkcapture";

// ---- runtime state --------------------------------------------------------
struct state {
    GMainLoop *loop;
    int        listen_fd;
    int        client_fd;        // the connected layer, or -1
    guint      listen_src;
    guint      client_src;
    guint      tick_src;         // fps sampling timer

    bool       test_mode;
    int        test_frames_left;
    const char *test_dump_path;

    // current shared frame geometry (from the latest capture_texture_data)
    bool       have_frame;
    int        width, height;
    uint32_t   fourcc;
    uint64_t   modifier;
    int        strides[4];
    int        offsets[4];
    int        nfd;
    int        fds[4];           // dmabuf fds we own (close on replace/exit)
    bool       flip;

    // mmap of fds[0] (the host-visible shared image)
    void      *map_ptr;
    size_t     map_len;

    // gstreamer
    GstElement *pipeline;
    GstAppSrc  *appsrc;
    bool        caps_set;
    bool        playing;         // pipeline moved to PLAYING (on first frame)
    int         fps;
    guint64     frame_no;
};

static struct state st = { .listen_fd = -1, .client_fd = -1 };

// ---- fourcc -> GStreamer format ------------------------------------------
// DRM fourccs are little-endian byte order in memory; map to the matching gst
// raw format. CS2's swapchain is almost certainly XRGB/ARGB8888 (BGRx/BGRA).
static const char *fourcc_to_gst(uint32_t f)
{
    switch (f) {
    case DRM_FORMAT_XRGB8888: return "BGRx";
    case DRM_FORMAT_ARGB8888: return "BGRA";
    case DRM_FORMAT_XBGR8888: return "RGBx";
    case DRM_FORMAT_ABGR8888: return "RGBA";
    default:                  return NULL;
    }
}

static void fourcc_str(uint32_t f, char out[5])
{
    out[0] = (char)(f & 0xff);
    out[1] = (char)((f >> 8) & 0xff);
    out[2] = (char)((f >> 16) & 0xff);
    out[3] = (char)((f >> 24) & 0xff);
    out[4] = '\0';
}

static void log_msg(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "[vkcap] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    fflush(stderr);
}

// ---- frame buffer teardown -----------------------------------------------
static void release_frame(void)
{
    if (st.map_ptr) { munmap(st.map_ptr, st.map_len); st.map_ptr = NULL; st.map_len = 0; }
    for (int i = 0; i < st.nfd; i++) {
        if (st.fds[i] >= 0) { close(st.fds[i]); st.fds[i] = -1; }
    }
    st.nfd = 0;
    st.have_frame = false;
}

// Reject bogus geometry off the wire before it feeds size math / memcpy, so a
// garbage frame can't overflow an allocation or read out of bounds.
#define VKCAP_MAX_DIM   16384
#define VKCAP_MAX_BYTES (256u * 1024 * 1024)
static bool geometry_ok(const struct capture_texture_data *td, int nfd)
{
    if (nfd < 1) return false;
    if (td->width  <= 0 || td->width  > VKCAP_MAX_DIM) return false;
    if (td->height <= 0 || td->height > VKCAP_MAX_DIM) return false;
    if (td->strides[0] < td->width * 4 || td->offsets[0] < 0) return false;
    int64_t bytes = (int64_t)td->strides[0] * td->height + td->offsets[0];
    return bytes > 0 && bytes <= VKCAP_MAX_BYTES;
}

// ---- control: tell the layer to start producing --------------------------
// Request a LINEAR, host-visible, no-modifier dmabuf so we can mmap + memcpy it
// with the CPU. (device_uuid left zero — single GPU; the layer allocates on its
// own device.)
static void send_control(int fd, bool capturing)
{
    struct capture_control_data c = {0};
    c.capturing    = capturing ? 1 : 0;
    c.no_modifiers = 1;
    c.linear       = 1;
    c.map_host     = 1;
    ssize_t n = write(fd, &c, sizeof(c));
    if (n != (ssize_t)sizeof(c))
        log_msg("WARN: send_control short write (%zd/%zu): %s", n, sizeof(c), strerror(errno));
}

// ---- push one sampled frame into the pipeline ----------------------------
static void set_caps_if_needed(void)
{
    if (st.caps_set) return;
    const char *gfmt = fourcc_to_gst(st.fourcc);
    if (!gfmt) {
        char fs[5]; fourcc_str(st.fourcc, fs);
        log_msg("ERROR: unsupported fourcc '%s' (0x%08x) — add it to fourcc_to_gst", fs, st.fourcc);
        gfmt = "BGRx"; // best guess so we at least produce something
    }
    GstCaps *caps = gst_caps_new_simple("video/x-raw",
        "format",    G_TYPE_STRING, gfmt,
        "width",     G_TYPE_INT, st.width,
        "height",    G_TYPE_INT, st.height,
        "framerate", GST_TYPE_FRACTION, st.fps, 1,
        NULL);
    gst_app_src_set_caps(st.appsrc, caps);
    gst_caps_unref(caps);
    st.caps_set = true;
    log_msg("appsrc caps: %s %dx%d @%dfps (stride0=%d flip=%d)",
            gfmt, st.width, st.height, st.fps, st.strides[0], st.flip);
}

static gboolean on_tick(gpointer user)
{
    (void)user;
    // Push only once PLAYING (delayed to the first frame so pulsesrc audio starts
    // in lockstep with video).
    if (!st.playing || !st.have_frame || !st.map_ptr || !st.appsrc) return G_SOURCE_CONTINUE;

    set_caps_if_needed();

    // Copy the shared host-mapped image into a fresh buffer (the layer overwrites
    // it on cs2's next present). Single plane assumed.
    const size_t row = (size_t)st.strides[0];
    const size_t sz  = row * (size_t)st.height;
    GstBuffer *buf = gst_buffer_new_allocate(NULL, sz, NULL);
    GstMapInfo mi;
    if (!gst_buffer_map(buf, &mi, GST_MAP_WRITE)) { gst_buffer_unref(buf); return G_SOURCE_CONTINUE; }

    const uint8_t *src = (const uint8_t *)st.map_ptr + st.offsets[0];
    if (st.flip) {
        for (int y = 0; y < st.height; y++)   // bottom-up -> top-down
            memcpy(mi.data + (size_t)y * row, src + (size_t)(st.height - 1 - y) * row, row);
    } else {
        memcpy(mi.data, src, sz);
    }
    gst_buffer_unmap(buf, &mi);

    // PTS is stamped by appsrc (do-timestamp=TRUE); downstream videorate locks CFR.
    GstFlowReturn fr = gst_app_src_push_buffer(st.appsrc, buf); // takes ownership
    if (fr != GST_FLOW_OK) {
        log_msg("appsrc push returned %d — stopping", fr);
        g_main_loop_quit(st.loop);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

// ---- TEST mode: log + dump one frame -------------------------------------
static void test_handle_frame(void)
{
    char fs[5]; fourcc_str(st.fourcc, fs);
    log_msg("TEXTURE #%llu: %dx%d fourcc=%s(0x%08x) modifier=0x%016llx nfd=%d "
            "stride0=%d offset0=%d flip=%d",
            (unsigned long long)st.frame_no, st.width, st.height, fs, st.fourcc,
            (unsigned long long)st.modifier, st.nfd, st.strides[0], st.offsets[0], st.flip);
    st.frame_no++;

    if (!st.map_ptr && st.nfd > 0 && st.fds[0] >= 0) {
        st.map_len = (size_t)st.strides[0] * (size_t)st.height + (size_t)st.offsets[0];
        st.map_ptr = mmap(NULL, st.map_len, PROT_READ, MAP_SHARED, st.fds[0], 0);
        if (st.map_ptr == MAP_FAILED) {
            st.map_ptr = NULL;
            log_msg("  mmap(fd0) FAILED: %s", strerror(errno));
        } else {
            log_msg("  mmap(fd0) OK (%zu bytes)", st.map_len);
            FILE *f = fopen(st.test_dump_path, "wb");
            if (f) {
                fwrite((uint8_t *)st.map_ptr + st.offsets[0], 1,
                       (size_t)st.strides[0] * (size_t)st.height, f);
                fclose(f);
                log_msg("  dumped one raw frame -> %s (%s %dx%d, view with: ffmpeg -f rawvideo "
                        "-pix_fmt bgra -s %dx%d -i %s frame.png)",
                        st.test_dump_path, fs, st.width, st.height, st.width, st.height,
                        st.test_dump_path);
            }
        }
    }

    if (--st.test_frames_left <= 0) {
        log_msg("TEST: captured enough — exiting. (host-map %s)",
                st.map_ptr ? "WORKS" : "did NOT work");
        g_main_loop_quit(st.loop);
    }
}

// ---- socket receive -------------------------------------------------------
static gboolean on_client_data(gint fd, GIOCondition cond, gpointer user)
{
    (void)user;
    if (cond & (G_IO_HUP | G_IO_ERR)) {
        log_msg("layer disconnected");
        goto drop;
    }

    uint8_t buf[CAPTURE_TEXTURE_DATA_SIZE];
    struct iovec io = { .iov_base = buf, .iov_len = sizeof(buf) };
    char cmsg_buf[CMSG_SPACE(sizeof(int)) * 4];
    struct msghdr msg = {0};
    msg.msg_iov = &io; msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf; msg.msg_controllen = sizeof(cmsg_buf);

    ssize_t n = recvmsg(fd, &msg, MSG_NOSIGNAL);
    if (n <= 0) {
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return G_SOURCE_CONTINUE;
        log_msg("layer recvmsg ended (%zd): %s", n, n < 0 ? strerror(errno) : "eof");
        goto drop;
    }

    switch (buf[0]) {
    case CAPTURE_CLIENT_DATA_TYPE: {
        struct capture_client_data *cd = (void *)buf;
        cd->exe[sizeof(cd->exe) - 1] = '\0';
        log_msg("layer hello: exe='%s' -> sending capturing=1 (linear+map_host)", cd->exe);
        send_control(fd, true);
        break;
    }
    case CAPTURE_TEXTURE_DATA_TYPE: {
        struct capture_texture_data *td = (void *)buf;
        // collect fds passed via SCM_RIGHTS
        int got_fds[4] = {-1,-1,-1,-1};
        int nfd = 0;
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
            if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
                nfd = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
                if (nfd > 4) nfd = 4;
                memcpy(got_fds, CMSG_DATA(c), nfd * sizeof(int));
                break;
            }
        }
        if (!geometry_ok(td, nfd)) {
            log_msg("ignoring texture: bad geometry %dx%d stride0=%d nfd=%d",
                    td->width, td->height, td->strides[0], nfd);
            for (int i = 0; i < nfd; i++) if (got_fds[i] >= 0) close(got_fds[i]);
            break;
        }
        // new shared texture -> drop the old mapping/fds
        release_frame();
        st.width = td->width; st.height = td->height; st.fourcc = (uint32_t)td->format;
        st.modifier = td->modifier; st.flip = td->flip != 0;
        memcpy(st.strides, td->strides, sizeof(st.strides));
        memcpy(st.offsets, td->offsets, sizeof(st.offsets));
        st.nfd = nfd;
        memcpy(st.fds, got_fds, sizeof(st.fds));
        st.caps_set = false; // geometry may have changed

        if (st.test_mode) {
            test_handle_frame();
            break;
        }
        // encode mode: mmap the shared image so on_tick can sample it.
        if (st.nfd < 1 || st.fds[0] < 0) break;
        st.map_len = (size_t)st.strides[0] * (size_t)st.height + (size_t)st.offsets[0];
        st.map_ptr = mmap(NULL, st.map_len, PROT_READ, MAP_SHARED, st.fds[0], 0);
        if (st.map_ptr == MAP_FAILED) {
            st.map_ptr = NULL;
            log_msg("ERROR: mmap(fd0) failed: %s", strerror(errno));
            break;
        }
        st.have_frame = true;
        log_msg("shared texture ready: %dx%d, sampling at %dfps", st.width, st.height, st.fps);
        // Go PLAYING now so audio (pulsesrc) starts in lockstep with video.
        if (!st.playing) {
            gst_element_set_state(st.pipeline, GST_STATE_PLAYING);
            st.playing = true;
        }
        break;
    }
    default:
        log_msg("unknown message type %u (%zd bytes)", buf[0], n);
        break;
    }
    return G_SOURCE_CONTINUE;

drop:
    release_frame();
    if (st.client_src) { g_source_remove(st.client_src); st.client_src = 0; }
    if (st.client_fd >= 0) { close(st.client_fd); st.client_fd = -1; }
    return G_SOURCE_REMOVE;
}

static gboolean on_listen(gint fd, GIOCondition cond, gpointer user)
{
    (void)cond; (void)user;
    int cfd = accept4(fd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
    if (cfd < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) log_msg("accept4: %s", strerror(errno));
        return G_SOURCE_CONTINUE;
    }
    if (st.client_fd >= 0) { // only one game at a time
        log_msg("second client connected — ignoring (already capturing)");
        close(cfd);
        return G_SOURCE_CONTINUE;
    }
    log_msg("layer connected (fd=%d)", cfd);
    st.client_fd = cfd;
    st.client_src = g_unix_fd_add(cfd, G_IO_IN | G_IO_HUP | G_IO_ERR, on_client_data, NULL);
    return G_SOURCE_CONTINUE;
}

// ---- shutdown -------------------------------------------------------------
static gboolean on_sigint(gpointer user)
{
    (void)user;
    log_msg("SIGINT — sending EOS and finalizing");
    if (st.tick_src) { g_source_remove(st.tick_src); st.tick_src = 0; }
    if (st.pipeline && st.playing) {
        // EOS the WHOLE pipeline (same as `gst-launch -e`) so BOTH the video appsrc
        // and the audio pulsesrc branch drain into qtmux and the moov atom is
        // written — EOS-ing only appsrc would leave audio open and truncate the mp4.
        gst_element_send_event(st.pipeline, gst_event_new_eos());
        // backstop in case EOS never reaches the bus (the EOS bus handler quits too)
        g_timeout_add(5000, (GSourceFunc)g_main_loop_quit, st.loop);
    } else {
        g_main_loop_quit(st.loop);
    }
    return G_SOURCE_REMOVE;
}

static gboolean on_bus(GstBus *bus, GstMessage *m, gpointer user)
{
    (void)bus; (void)user;
    switch (GST_MESSAGE_TYPE(m)) {
    case GST_MESSAGE_EOS:
        log_msg("pipeline EOS");
        g_main_loop_quit(st.loop);
        break;
    case GST_MESSAGE_ERROR: {
        GError *e = NULL; gchar *dbg = NULL;
        gst_message_parse_error(m, &e, &dbg);
        log_msg("pipeline ERROR: %s | %s", e ? e->message : "?", dbg ? dbg : "");
        if (e) g_error_free(e); g_free(dbg);
        g_main_loop_quit(st.loop);
        break;
    }
    default: break;
    }
    return TRUE;
}

// ---- socket setup ---------------------------------------------------------
static int make_listen_socket(void)
{
    int fd = socket(PF_LOCAL, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) { log_msg("socket: %s", strerror(errno)); return -1; }
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_LOCAL;
    addr.sun_path[0] = '\0'; // abstract namespace
    memcpy(&addr.sun_path[1], SOCK_NAME, sizeof(SOCK_NAME) - 1);
    socklen_t len = offsetof(struct sockaddr_un, sun_path) + 1 + (sizeof(SOCK_NAME) - 1);
    if (bind(fd, (struct sockaddr *)&addr, len) < 0) {
        log_msg("bind %s: %s (another consumer/OBS already running?)", SOCK_NAME, strerror(errno));
        close(fd); return -1;
    }
    if (listen(fd, 1) < 0) { log_msg("listen: %s", strerror(errno)); close(fd); return -1; }
    return fd;
}

int main(int argc, char **argv)
{
    st.test_mode = getenv("VKCAP_TEST") && atoi(getenv("VKCAP_TEST")) != 0;
    st.test_dump_path = getenv("VKCAP_TEST_DUMP"); if (!st.test_dump_path) st.test_dump_path = "/tmp/vkcap-frame.raw";
    st.test_frames_left = getenv("VKCAP_TEST_FRAMES") ? atoi(getenv("VKCAP_TEST_FRAMES")) : 5;
    st.fps = getenv("VKCAP_FPS") ? atoi(getenv("VKCAP_FPS")) : 60;
    if (st.fps <= 0) st.fps = 60;
    for (int i = 0; i < 4; i++) st.fds[i] = -1;

    if (!st.test_mode) {
        if (argc < 2) {
            log_msg("usage: %s '<gstreamer pipeline with appsrc name=vksrc>'   (or VKCAP_TEST=1 %s)",
                    argv[0], argv[0]);
            return 2;
        }
        gst_init(&argc, &argv);
        GError *err = NULL;
        // FATAL_ERRORS: a missing element must fail here so the shell falls back to
        // ximagesrc, not return a half-linked pipeline that limps to "not-linked".
        st.pipeline = gst_parse_launch_full(argv[1], NULL, GST_PARSE_FLAG_FATAL_ERRORS, &err);
        if (!st.pipeline) { log_msg("bad pipeline: %s", err ? err->message : "?"); return 2; }
        GstElement *src = gst_bin_get_by_name(GST_BIN(st.pipeline), "vksrc");
        if (!src) { log_msg("pipeline has no element named 'vksrc'"); return 2; }
        st.appsrc = GST_APP_SRC(src);
        gst_app_src_set_stream_type(st.appsrc, GST_APP_STREAM_TYPE_STREAM);
        g_object_set(src, "is-live", TRUE, "format", GST_FORMAT_TIME, "do-timestamp", TRUE, NULL);
        GstBus *bus = gst_element_get_bus(st.pipeline);
        gst_bus_add_watch(bus, on_bus, NULL);
        gst_object_unref(bus);
        // READY (not PLAYING): we flip to PLAYING when the first frame arrives, so
        // the live pulsesrc audio starts together with video (no audio lead-in).
        gst_element_set_state(st.pipeline, GST_STATE_READY);
    } else {
        log_msg("TEST mode: will log %d texture update(s), dump to %s, no encode",
                st.test_frames_left, st.test_dump_path);
    }

    st.listen_fd = make_listen_socket();
    if (st.listen_fd < 0) return 1;

    st.loop = g_main_loop_new(NULL, FALSE);
    st.listen_src = g_unix_fd_add(st.listen_fd, G_IO_IN, on_listen, NULL);
    g_unix_signal_add(SIGINT,  on_sigint, NULL);
    g_unix_signal_add(SIGTERM, on_sigint, NULL);
    if (!st.test_mode) {
        guint interval_ms = (guint)(1000 / st.fps);
        if (interval_ms < 1) interval_ms = 1;   // clamp: absurd VKCAP_FPS -> 0 -> busy loop
        st.tick_src = g_timeout_add(interval_ms, on_tick, NULL);
    } else {
        // TEST mode always terminates: the layer may send texture metadata only
        // ONCE (then you sample asynchronously), so don't rely on the frame count.
        guint secs = getenv("VKCAP_TEST_SECS") ? (guint)atoi(getenv("VKCAP_TEST_SECS")) : 15;
        g_timeout_add_seconds(secs, (GSourceFunc)g_main_loop_quit, st.loop);
    }

    log_msg("listening on %s (test=%d fps=%d) — waiting for cs2's vkcapture layer",
            SOCK_NAME, st.test_mode, st.fps);
    g_main_loop_run(st.loop);

    // teardown
    if (st.pipeline) {
        gst_element_set_state(st.pipeline, GST_STATE_NULL);
        gst_object_unref(st.pipeline);
    }
    release_frame();
    if (st.client_fd >= 0) close(st.client_fd);
    if (st.listen_fd >= 0) close(st.listen_fd);
    log_msg("exit");
    return 0;
}
