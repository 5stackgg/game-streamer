#include <stdio.h>
#include "flow-diag.h"

static guint lines;
static void emit(const char *line) { puts(line); lines++; }
static VkcapFlowStage *stage(VkcapFlowDiag *d, const char *name)
{
    for (guint i = 0; i < d->count; i++)
        if (g_strcmp0(d->stages[i].stage, name) == 0) return &d->stages[i];
    g_error("Missing stage %s", name);
    return NULL;
}
static GstElement *parse(const char *description)
{
    GError *error = NULL;
    GstElement *pipeline = gst_parse_launch(description, &error);
    g_assert_no_error(error); g_assert_nonnull(pipeline);
    return pipeline;
}
static guint64 read_count(VkcapFlowStage *s)
{
    g_mutex_lock(&s->lock); guint64 n = s->buffers; g_mutex_unlock(&s->lock); return n;
}
static void handoff(GstElement *sink, GstBuffer *buffer, GstPad *pad, gpointer user)
{
    (void)sink; (void)buffer; (void)pad;
    (*(guint *)user)++;
}
int main(int argc, char **argv)
{
    gst_init(&argc, &argv);
    // A real streaming pipeline with a slow downstream stage must report where
    // 60 input buffers/s become ~5 output buffers/s, without throttling the source.
    GstElement *pipeline = parse("videotestsrc name=vksrc is-live=true ! "
        "video/x-raw,width=64,height=36,framerate=60/1 ! "
        "queue leaky=downstream max-size-buffers=2 ! identity sleep-time=200000 ! "
        "x264enc tune=zerolatency speed-preset=ultrafast ! h264parse ! fakesink sync=false");
    g_assert_null(vkcap_flow_start(pipeline, FALSE));
    VkcapFlowDiag *d = vkcap_flow_start(pipeline, TRUE);
    g_assert_cmpuint(d->count, ==, 4);
    g_assert_cmpint(gst_element_set_state(pipeline, GST_STATE_PLAYING), !=, GST_STATE_CHANGE_FAILURE);
    g_usleep(2200000);
    guint64 input = read_count(stage(d, "capture-out"));
    guint64 encoded = read_count(stage(d, "encoder-out"));
    g_assert_cmpuint(input, >=, 90); g_assert_cmpuint(encoded, >=, 5);
    g_assert_cmpuint(encoded, <=, 15); g_assert_cmpuint(input, >, encoded * 5);
    vkcap_flow_report(d, 2200 * GST_MSECOND, emit);
    g_assert_cmpuint(lines, ==, 4);
    g_assert_cmpuint(read_count(stage(d, "encoder-out")), <=, 1);
    gst_element_set_state(pipeline, GST_STATE_NULL); vkcap_flow_free(d); gst_object_unref(pipeline);

    // MPEG-TS sinks may receive lists rather than individual buffers.
    VkcapFlowStage counter = {0}; g_mutex_init(&counter.lock);
    GstBufferList *list = gst_buffer_list_new();
    for (guint i = 1; i <= 3; i++) gst_buffer_list_add(list, gst_buffer_new_allocate(NULL, i * 188, NULL));
    GstPadProbeInfo info = {0}; info.type = GST_PAD_PROBE_TYPE_BUFFER_LIST; info.data = list;
    g_assert_cmpint(vkcap_flow_count(NULL, &info, &counter), ==, GST_PAD_PROBE_OK);
    g_assert_cmpuint(counter.buffers, ==, 3); g_assert_cmpuint(counter.bytes, ==, 1128);
    gst_buffer_list_unref(list); g_mutex_clear(&counter.lock);

    // Attaching diagnostics leaves a finite encode's output count unchanged.
    for (guint enabled = 0; enabled <= 1; enabled++) {
        pipeline = parse("videotestsrc name=vksrc num-buffers=60 ! "
            "video/x-raw,width=64,height=36,framerate=60/1 ! "
            "x264enc tune=zerolatency speed-preset=ultrafast ! h264parse ! "
            "fakesink name=output sync=false signal-handoffs=true");
        guint count = 0;
        GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "output");
        g_signal_connect(sink, "handoff", G_CALLBACK(handoff), &count);
        d = vkcap_flow_start(pipeline, enabled);
        GstBus *bus = gst_element_get_bus(pipeline);
        gst_element_set_state(pipeline, GST_STATE_PLAYING);
        GstMessage *message = gst_bus_timed_pop_filtered(bus, 5 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
        g_assert_nonnull(message); g_assert_cmpint(GST_MESSAGE_TYPE(message), ==, GST_MESSAGE_EOS);
        gst_element_set_state(pipeline, GST_STATE_NULL);
        g_assert_cmpuint(count, ==, 60);
        vkcap_flow_free(d); gst_message_unref(message);
        gst_object_unref(bus); gst_object_unref(sink); gst_object_unref(pipeline);
    }
    puts("PASS: slow-stage identification, buffer-list counts, disabled mode, unchanged encode output");
    return 0;
}
