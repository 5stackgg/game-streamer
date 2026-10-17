"""Exercise appsrc buffering on the shipped GStreamer runtime, without a GPU."""
import ctypes as C,json,time,re,sys
from pathlib import Path
gst=C.CDLL('libgstreamer-1.0.so.0');app=C.CDLL('libgstapp-1.0.so.0');obj=C.CDLL('libgobject-2.0.so.0')
gst.gst_init.argtypes=[C.c_void_p,C.c_void_p];gst.gst_init(None,None)
gst.gst_version_string.restype=C.c_char_p
gst.gst_parse_launch.argtypes=[C.c_char_p,C.POINTER(C.c_void_p)];gst.gst_parse_launch.restype=C.c_void_p
gst.gst_bin_get_by_name.argtypes=[C.c_void_p,C.c_char_p];gst.gst_bin_get_by_name.restype=C.c_void_p
gst.gst_element_set_state.argtypes=[C.c_void_p,C.c_int];gst.gst_element_set_state.restype=C.c_int
gst.gst_buffer_new_allocate.argtypes=[C.c_void_p,C.c_size_t,C.c_void_p];gst.gst_buffer_new_allocate.restype=C.c_void_p
gst.gst_buffer_memset.argtypes=[C.c_void_p,C.c_size_t,C.c_int,C.c_size_t];gst.gst_buffer_memset.restype=C.c_size_t
app.gst_app_src_push_buffer.argtypes=[C.c_void_p,C.c_void_p];app.gst_app_src_push_buffer.restype=C.c_int
obj.g_object_get.argtypes=[C.c_void_p,C.c_char_p];obj.g_object_unref.argtypes=[C.c_void_p];obj.g_object_unref.restype=None
def level(element,wide):
 value=C.c_uint64() if wide else C.c_uint();obj.g_object_get(element,b'current-level-buffers',C.byref(value),None);return value.value
def exercise(prefix):
 prefix=prefix.replace('! queue','! queue name=samplequeue',1)
 prefix=prefix.replace('appsrc name=vksrc','appsrc name=vksrc is-live=true format=time do-timestamp=true caps=video/x-raw,format=GRAY8,width=16,height=16,framerate=60/1',1)
 error=C.c_void_p();pipeline=gst.gst_parse_launch((prefix+' ! identity sleep-time=100000 ! fakesink sync=false').encode(),C.byref(error));assert pipeline and not error.value,'Could not parse test graph'
 src=gst.gst_bin_get_by_name(pipeline,b'vksrc');queue=gst.gst_bin_get_by_name(pipeline,b'samplequeue');assert src and queue
 peak_src=peak_queue=0
 try:
  assert gst.gst_element_set_state(pipeline,4)!=0
  for _ in range(120):
   buffer=gst.gst_buffer_new_allocate(None,256,None);assert buffer;gst.gst_buffer_memset(buffer,0,0,256)
   assert app.gst_app_src_push_buffer(src,buffer)==0
   peak_src=max(peak_src,level(src,True));peak_queue=max(peak_queue,level(queue,False));time.sleep(1/60)
  return {'peak_appsrc_buffers':peak_src,'peak_downstream_queue_buffers':peak_queue,'frames_pushed':120}
 finally:
  gst.gst_element_set_state(pipeline,1);obj.g_object_unref(src);obj.g_object_unref(queue);obj.g_object_unref(pipeline)
baseline=exercise('appsrc name=vksrc ! queue')
source=Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).with_name('stream.sh')
match=re.search(r'^\s*local cs2_src="([^"]+)"',source.read_text(),re.M)
assert match and 'comp.sink_0' in match[1], 'Live composite input pipeline not found'
actual=match[1].replace('$fps','60').split(' ! videorate',1)[0]
bounded=exercise(actual)
assert baseline['peak_appsrc_buffers']>=8,baseline
assert bounded['peak_appsrc_buffers']<=2 and bounded['peak_downstream_queue_buffers']<=2,bounded
print(json.dumps({'shipped_gstreamer':gst.gst_version_string().decode(),'baseline_unbounded':baseline,'bounded_live_input':bounded,'backpressure_regression_proved':True}),flush=True)
