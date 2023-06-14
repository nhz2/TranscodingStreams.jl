# An insane codec for testing the codec APIs.
struct QuadrupleCodec <: TranscodingStreams.Codec end

function TranscodingStreams.process(
        codec  :: QuadrupleCodec,
        input  :: TranscodingStreams.Memory,
        output :: TranscodingStreams.Memory,
        error  :: TranscodingStreams.Error)
    i = j = 0
    while i + 1 ≤ lastindex(input) && j + 4 ≤ lastindex(output)
        b = input[i+1]
        i += 1
        output[j+1] = output[j+2] = output[j+3] = output[j+4] = b
        j += 4
    end
    return i, j, input.size == 0 ? (:end) : (:ok)
end

function TranscodingStreams.expectedsize(
              :: QuadrupleCodec,
        input :: TranscodingStreams.Memory)
    return input.size * 4
end

function TranscodingStreams.minoutsize(
        :: QuadrupleCodec,
        :: TranscodingStreams.Memory)
    return 4
end

@testset "Quadruple Codec" begin
    @test transcode(QuadrupleCodec, b"") == b""
    @test transcode(QuadrupleCodec, b"a") == b"aaaa"
    @test transcode(QuadrupleCodec, b"ab") == b"aaaabbbb"
    @test transcode(QuadrupleCodec(), b"") == b""
    @test transcode(QuadrupleCodec(), b"a") == b"aaaa"
    @test transcode(QuadrupleCodec(), b"ab") == b"aaaabbbb"

    #=
    data = "x"^1024
    transcode(QuadrupleCodec(), data)
    @test (@allocated transcode(QuadrupleCodec(), data)) < sizeof(data) * 5
    =#

    stream = TranscodingStream(QuadrupleCodec(), NoopStream(IOBuffer("foo")))
    @test read(stream) == b"ffffoooooooo"
    close(stream)

    stream = NoopStream(TranscodingStream(QuadrupleCodec(), NoopStream(IOBuffer("foo"))))
    @test read(stream) == b"ffffoooooooo"
    close(stream)

    stream = TranscodingStream(QuadrupleCodec(), IOBuffer("foo"))
    @test position(stream) === 0
    read(stream, 3)
    @test position(stream) === 3
    read(stream, UInt8)
    @test position(stream) === 4
    close(stream)

    stream = TranscodingStream(QuadrupleCodec(), IOBuffer())
    @test position(stream) === 0
    write(stream, 0x00)
    @test position(stream) === 1
    write(stream, "foo")
    @test position(stream) === 4
    close(stream)

    # Buffers are shared.
    stream1 = TranscodingStream(QuadrupleCodec(), IOBuffer("foo"))
    stream2 = TranscodingStream(QuadrupleCodec(), stream1)
    @test stream1.state.buffer1 === stream2.state.buffer2
    close(stream1)
    close(stream2)

    # Explicitly unshare buffers.
    stream1 = TranscodingStream(QuadrupleCodec(), IOBuffer("foo"))
    stream2 = TranscodingStream(QuadrupleCodec(), stream1, sharedbuf=false)
    @test stream1.state.buffer1 !== stream2.state.buffer2
    close(stream1)
    close(stream2)

    stream = TranscodingStream(QuadrupleCodec(), IOBuffer("foo"))
    @test_throws EOFError unsafe_read(stream, pointer(Vector{UInt8}(undef, 13)), 13)
    close(stream)

    @testset "position" begin
        iob = IOBuffer()
        sink = IOBuffer()
        stream = TranscodingStream(QuadrupleCodec(), sink, bufsize=16)
        @test position(stream) == position(iob)
        for len in 0:10:100
            write(stream, repeat("x", len))
            write(iob, repeat("x", len))
            @test position(stream) == position(iob)
        end
        close(stream)
        close(iob)

        mktemp() do path, sink
            stream = TranscodingStream(QuadrupleCodec(), sink, bufsize=16)
            pos = 0
            for len in 0:10:100
                write(stream, repeat("x", len))
                pos += len
                @test position(stream) == pos
            end
        end
    end
    @testset "seeking write" begin
        iob = IOBuffer()
        sink = IOBuffer(collect(b"this will be over written"); write=true)
        seekstart(sink)
        stream = TranscodingStream(QuadrupleCodec(), sink, bufsize=16)
        @test position(stream) == 0
        # seekend in :idle mode should just change mode to write.
        # This is to prevent future reads from getting the wrong position.
        seekend(stream)
        @test eof(stream)
        @test position(stream) == 0
        for len in 0:10:100
            write(stream, repeat("x", len))
            # seekend in :write mode should be a noop.
            # because stream can generally only write at the end.
            seekend(stream)
            write(iob, repeat("x", len))
            seekend(iob)
            @test position(stream) == position(iob)
        end
        # seekstart in :write mode will by default error
        @test_throws ArgumentError seekstart(stream)
        @test_throws MethodError seek(stream, 3)

        @test position(stream) == position(iob)

        # close stream but not underlying IO.
        # This should probably be defined as a public function.
        TranscodingStreams.changemode!(stream, :close)
        @test 4*length(take!(iob)) == length(take!(sink))

        close(stream)
        close(iob)
    end
    @testset "seeking read" begin
        source = IOBuffer(collect(0x01:0xAF); append=true, read=true, write=true)
        stream = TranscodingStream(QuadrupleCodec(), source, bufsize=16)
        @test position(stream) == 0
        # seekstart in :idle mode should seekstart of wrapped IO.
        seekstart(stream)
        @test position(stream) == 0
        @test read(stream, 11) == [1,1,1,1,2,2,2,2,3,3,3,]
        @test position(stream) == 11
        # seekstart in :read mode should reset reader and seekstart of wrapped IO.
        seekstart(stream)
        @test position(stream) == 0
        @test read(stream, 11) == [1,1,1,1,2,2,2,2,3,3,3,]
        @test position(stream) == 11
        # seekend in :read mode will create a warning
        @test_logs (:warn,"seekend while in :read mode is currently buggy") seekend(stream)
        @test_throws MethodError seek(stream, 3)
        close(stream)
    end
end
