# This file is a part of Julia. License is MIT: https://julialang.org/license

# Generate encode table.
const BASE64_ENCODE = [UInt8(x) for x in ['A':'Z'; 'a':'z'; '0':'9'; '+'; '/']]

# '-' and '_' instead of '+' and '/'
const BASE64URL_ENCODE = [UInt8(x) for x in ['A':'Z'; 'a':'z'; '0':'9'; '-'; '_']]

encode_base64(x::UInt8) = @inbounds return BASE64_ENCODE[(x & 0x3f) + 1]
encode_base64url(x::UInt8) = @inbounds return BASE64URL_ENCODE[(x & 0x3f) + 1]
encodepadding()  = UInt8('=')

struct Base64EncodePipe{F<:Function} <: IO
    io::IO
    buffer::Buffer
    encode::F

    function Base64EncodePipe(io::IO; encoder::T=encode_base64) where {T<:Function}
        # The buffer size must be at least 3.
        buffer = Buffer(512)
        pipe = new{T}(io, buffer, encoder)
        finalizer(_ -> close(pipe), buffer)
        return pipe
    end
end

function Base.unsafe_write(pipe::Base64EncodePipe, ptr::Ptr{UInt8}, n::UInt)::Int
    buffer = pipe.buffer
    m = buffer.size
    b1, b2, b3, k = loadtriplet!(buffer, ptr, n)
    @assert k ≥ m
    p = ptr + k - m
    if k < 3
        if k == 1
            buffer[1] = b1
            buffer.size = 1
        elseif k == 2
            buffer[1] = b1
            buffer[2] = b2
            buffer.size = 2
        end
        return p - ptr
    end
    @assert buffer.size == 0

    i = 0
    p_end = ptr + n
    while true
        buffer[i+1] = pipe.encode(b1 >> 2          )
        buffer[i+2] = pipe.encode(b1 << 4 | b2 >> 4)
        buffer[i+3] = pipe.encode(b2 << 2 | b3 >> 6)
        buffer[i+4] = pipe.encode(          b3     )
        i += 4
        if p + 2 < p_end
            b1 = unsafe_load(p, 1)
            b2 = unsafe_load(p, 2)
            b3 = unsafe_load(p, 3)
            p += 3
        else
            break
        end
        if i + 4 > capacity(buffer)
            unsafe_write(pipe.io, pointer(buffer), i)
            i = 0
        end
    end
    if i > 0
        unsafe_write(pipe.io, pointer(buffer), i)
    end

    while p < p_end
        buffer[buffer.size+=1] = unsafe_load(p)
        p += 1
    end
    return p - ptr
end

function Base.write(pipe::Base64EncodePipe, x::UInt8)
    buffer = pipe.buffer
    buffer[buffer.size+=1] = x
    if buffer.size == 3
        unsafe_write(pipe, C_NULL, 0)
    end
    return 1
end

function Base.close(pipe::Base64EncodePipe)
    b1, b2, b3, k = loadtriplet!(pipe.buffer, Ptr{UInt8}(C_NULL), UInt(0))
    if k == 0
        # no leftover and padding
    elseif k == 1
        write(pipe.io,
              pipe.encode(b1 >> 2),
              pipe.encode(b1 << 4),
              encodepadding(),
              encodepadding())
    elseif k == 2
        write(pipe.io,
              pipe.encode(          b1 >> 2),
              pipe.encode(b1 << 4 | b2 >> 4),
              pipe.encode(b2 << 2          ),
              encodepadding())
    else
        @assert k == 3
        write(pipe.io,
              pipe.encode(b1 >> 2          ),
              pipe.encode(b1 << 4 | b2 >> 4),
              pipe.encode(b2 << 2 | b3 >> 6),
              pipe.encode(          b3     ))
    end
    return nothing
end

# Load three bytes from buffer and ptr.
function loadtriplet!(buffer::Buffer, ptr::Ptr{UInt8}, n::UInt)
    b1 = b2 = b3 = 0x00
    if buffer.size == 0
        if n == 0
            k = 0
        elseif n == 1
            b1 = unsafe_load(ptr, 1)
            k = 1
        elseif n == 2
            b1 = unsafe_load(ptr, 1)
            b2 = unsafe_load(ptr, 2)
            k = 2
        else
            b1 = unsafe_load(ptr, 1)
            b2 = unsafe_load(ptr, 2)
            b3 = unsafe_load(ptr, 3)
            k = 3
        end
    elseif buffer.size == 1
        b1 = buffer[1]
        if n == 0
            k = 1
        elseif n == 1
            b2 = unsafe_load(ptr, 1)
            k = 2
        else
            b2 = unsafe_load(ptr, 1)
            b3 = unsafe_load(ptr, 2)
            k = 3
        end
    elseif buffer.size == 2
        b1 = buffer[1]
        b2 = buffer[2]
        if n == 0
            k = 2
        else
            b3 = unsafe_load(ptr, 1)
            k = 3
        end
    else
        @assert buffer.size == 3
        b1 = buffer[1]
        b2 = buffer[2]
        b3 = buffer[3]
        k = 3
    end
    empty!(buffer)
    return b1, b2, b3, k
end

function base64encode(f::Function, args...; context=nothing)
    s = IOBuffer()
    b = Base64EncodePipe(s)
    if context === nothing
        f(b, args...)
    else
        f(IOContext(b, context), args...)
    end
    close(b)
    return String(take!(s))
end
base64encode(args...; context=nothing) = base64encode(write, args...; context=context)

function base64urlencode(f::Function, args...; context=nothing)
    s = IOBuffer()
    b = Base64EncodePipe(s, encoder=encode_base64url)
    if context === nothing
        f(b, args...)
    else
        f(IOContext(b, context), args...)
    end
    close(b)
    return String(take!(s))
end
base64urlencode(args...; context=nothing) = base64urlencode(write, args...; context=context)
