local M={}
function M.gunzip(data,limit)
    local ffi=require("ffi")
    ffi.cdef[[
        typedef struct {
            const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
            unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
            char *msg; void *state; void *zalloc; void *zfree; void *opaque;
            int data_type; unsigned long adler; unsigned long reserved;
        } coverlab_z_stream;
        const char *zlibVersion(void);
        int inflateInit2_(coverlab_z_stream *, int, const char *, int);
        int inflate(coverlab_z_stream *, int);
        int inflateEnd(coverlab_z_stream *);
    ]]
    local z=ffi.loadlib("z",1)
    local stream=ffi.new("coverlab_z_stream[1]")
    local out=ffi.new("unsigned char[?]",limit+1)
    stream[0].next_in=data;stream[0].avail_in=#data
    stream[0].next_out=out;stream[0].avail_out=limit+1
    if z.inflateInit2_(stream,31,z.zlibVersion(),ffi.sizeof(stream[0])) ~= 0 then return nil,"Cannot initialise gzip decoder." end
    local status=z.inflate(stream,4)
    local n=tonumber(stream[0].total_out)
    z.inflateEnd(stream)
    if status ~= 1 or n > limit then return nil,"Compressed response is invalid or exceeds the size limit." end
    return ffi.string(out,n)
end
return M
