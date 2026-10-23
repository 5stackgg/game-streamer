// Optional metadata-only flow counters. No frame mapping, copies or pipeline changes.
#pragma once
#include <gst/gst.h>

#define VKCAP_FLOW_MAX_STAGES 24
typedef struct {
    GstPad *pad;
    gulong probe;
    const char *stage;
    GMutex lock;
    guint64 buffers, bytes;
    GstClockTime pts;
} VkcapFlowStage;

typedef struct {
    VkcapFlowStage stages[VKCAP_FLOW_MAX_STAGES];
    guint count;
    gint64 last_us;
} VkcapFlowDiag;

static GstPadProbeReturn vkcap_flow_count(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    (void)pad;
    VkcapFlowStage *s = user;
    guint64 buffers = 0, bytes = 0;
    GstClockTime pts = GST_CLOCK_TIME_NONE;
    if (GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_BUFFER) {
        GstBuffer *b = GST_PAD_PROBE_INFO_BUFFER(info);
        buffers = 1; bytes = gst_buffer_get_size(b); pts = GST_BUFFER_PTS(b);
    } else if (GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_BUFFER_LIST) {
        GstBufferList *list = GST_PAD_PROBE_INFO_BUFFER_LIST(info);
        buffers = gst_buffer_list_length(list);
        for (guint i = 0; i < buffers; i++) {
            GstBuffer *b = gst_buffer_list_get(list, i);
            bytes += gst_buffer_get_size(b); pts = GST_BUFFER_PTS(b);
        }
    }
    g_mutex_lock(&s->lock);
    s->buffers += buffers; s->bytes += bytes;
    if (GST_CLOCK_TIME_IS_VALID(pts)) s->pts = pts;
    g_mutex_unlock(&s->lock);
    return GST_PAD_PROBE_OK;
}

static void vkcap_flow_add(VkcapFlowDiag *d, GstElement *e, const char *pad_name, const char *stage)
{
    if (d->count == VKCAP_FLOW_MAX_STAGES) return;
    GstPad *pad = gst_element_get_static_pad(e, pad_name);
    if (!pad) return;
    VkcapFlowStage *s = &d->stages[d->count++];
    s->pad = pad; s->stage = stage; s->pts = GST_CLOCK_TIME_NONE;
    g_mutex_init(&s->lock);
    s->probe = gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER | GST_PAD_PROBE_TYPE_BUFFER_LIST,
                                vkcap_flow_count, s, NULL);
}

// Caller explicitly opts in. No timer or pad callback exists when disabled.
static VkcapFlowDiag *vkcap_flow_start(GstElement *pipeline, gboolean enabled)
{
    if (!enabled) return NULL;
    VkcapFlowDiag *d = g_new0(VkcapFlowDiag, 1);
    d->last_us = g_get_monotonic_time();
    GstIterator *it = gst_bin_iterate_recurse(GST_BIN(pipeline));
    GValue value = G_VALUE_INIT;
    gboolean done = FALSE;
    while (!done) {
        switch (gst_iterator_next(it, &value)) {
        case GST_ITERATOR_OK: {
            GstElement *e = g_value_get_object(&value);
            GstElementFactory *factory = gst_element_get_factory(e);
            const char *f = factory ? gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory)) : "";
            if (g_strcmp0(GST_ELEMENT_NAME(e), "vksrc") == 0)
                vkcap_flow_add(d, e, "src", "capture-out");
            else if (g_strcmp0(f, "ximagesrc") == 0)
                vkcap_flow_add(d, e, "src", "ximage-out");
            else if (g_strcmp0(f, "compositor") == 0) {
                vkcap_flow_add(d, e, "sink_0", "game-in");
                vkcap_flow_add(d, e, "sink_1", "hud-in");
                vkcap_flow_add(d, e, "src", "blend-out");
            } else if (g_strcmp0(f, "vapostproc") == 0 ||
                       (g_str_has_prefix(f, "varenderD") && g_str_has_suffix(f, "postproc")) ||
                       g_strcmp0(f, "cudaconvertscale") == 0) {
                vkcap_flow_add(d, e, "sink", "gpu-convert-in");
                vkcap_flow_add(d, e, "src", "gpu-convert-out");
            } else if (g_str_has_suffix(f, "h264enc") || g_str_has_suffix(f, "h265enc") ||
                       g_strcmp0(f, "x264enc") == 0) {
                vkcap_flow_add(d, e, "sink", "encoder-in");
                vkcap_flow_add(d, e, "src", "encoder-out");
            } else if (g_strcmp0(f, "h264parse") == 0 || g_strcmp0(f, "h265parse") == 0)
                vkcap_flow_add(d, e, "src", "parser-out");
            else if (g_strcmp0(f, "srtsink") == 0)
                vkcap_flow_add(d, e, "sink", "srt-in");
            g_value_reset(&value);
            break;
        }
        // Pipeline construction is finished before attachment. If it changes,
        // stop discovery; resyncing could attach duplicate probes.
        default: done = TRUE; break;
        }
    }
    if (G_IS_VALUE(&value)) g_value_unset(&value);
    gst_iterator_free(it);
    return d;
}

// Logs only stage counters and negotiated video geometry. Output units are pad
// buffers, not necessarily frames: for example srt-in counts MPEG-TS buffers.
static void vkcap_flow_report(VkcapFlowDiag *d, GstClockTime running_time,
                              void (*emit)(const char *))
{
    if (!d) return;
    gint64 now = g_get_monotonic_time(), elapsed = now - d->last_us;
    if (elapsed <= 0) return;
    d->last_us = now;
    for (guint i = 0; i < d->count; i++) {
        VkcapFlowStage *s = &d->stages[i];
        g_mutex_lock(&s->lock);
        guint64 buffers = s->buffers, bytes = s->bytes;
        GstClockTime pts = s->pts;
        s->buffers = s->bytes = 0;
        g_mutex_unlock(&s->lock);
        gint width = 0, height = 0, fps_n = 0, fps_d = 1;
        GstCaps *caps = gst_pad_get_current_caps(s->pad);
        if (caps && !gst_caps_is_empty(caps)) {
            const GstStructure *c = gst_caps_get_structure(caps, 0);
            gst_structure_get_int(c, "width", &width);
            gst_structure_get_int(c, "height", &height);
            gst_structure_get_fraction(c, "framerate", &fps_n, &fps_d);
        }
        if (caps) gst_caps_unref(caps);
        GstClockTime position = GST_CLOCK_TIME_NONE;
        GstEvent *event = gst_pad_get_sticky_event(s->pad, GST_EVENT_SEGMENT, 0);
        if (event) {
            const GstSegment *segment;
            gst_event_parse_segment(event, &segment);
            if (segment->format == GST_FORMAT_TIME && GST_CLOCK_TIME_IS_VALID(pts))
                position = gst_segment_to_running_time(segment, GST_FORMAT_TIME, pts);
            gst_event_unref(event);
        }
        gint64 lag_ms = GST_CLOCK_TIME_IS_VALID(position) && GST_CLOCK_TIME_IS_VALID(running_time)
                        ? GST_CLOCK_DIFF(position, running_time) / GST_MSECOND : -1;
        gchar *line = g_strdup_printf("FLOW-DIAG stage=%s buffers=%" G_GUINT64_FORMAT
            " buffers_per_s=%.2f bytes=%" G_GUINT64_FORMAT " window_ms=%" G_GINT64_FORMAT
            " pts_lag_ms=%" G_GINT64_FORMAT " width=%d height=%d caps_fps=%d/%d",
            s->stage, buffers, buffers * 1000000.0 / elapsed, bytes, elapsed / 1000,
            lag_ms, width, height, fps_n, fps_d);
        emit(line); g_free(line);
    }
}

// Call after the pipeline reaches NULL, so no streaming callback can still use d.
static void vkcap_flow_free(VkcapFlowDiag *d)
{
    if (!d) return;
    for (guint i = 0; i < d->count; i++) {
        VkcapFlowStage *s = &d->stages[i];
        gst_pad_remove_probe(s->pad, s->probe);
        gst_object_unref(s->pad); g_mutex_clear(&s->lock);
    }
    g_free(d);
}
