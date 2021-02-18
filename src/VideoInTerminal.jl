"""
    VideoInTerminal

Video playback in the terminal via. ImageInTerminal and VideoIO

- `play(framestack)` where `framestack` is a vector of image arrays
- `play(fpath::String)` where fpath is a path to a video file
- `webcam()` to stream the default webcam
- `testvideo(name)` to show a VideoIO test video, such as "annie_oakley", or "ladybird"

`ImageInTerminal` is re-exported to expose core controls:
- `ImageInTerminal.use_24bit()` force using 24-bit color
- `ImageInTerminal.use_256()` force using 256 colors
"""
module VideoInTerminal

using ImageCore, ImageInTerminal, VideoIO

import ImageInTerminal: TermColor256, encodeimg, SmallBlocks, use_256, use_24bit

export play, webcam, testvideo
export ImageInTerminal

ansi_moveup(n::Int) = string("\e[", n, "A")
ansi_movecol1 = "\e[1G"
ansi_cleartoend = "\e[0J"
ansi_enablecursor = "\e[?25h"
ansi_disablecursor = "\e[?25l"

setraw!(io, raw) = ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid},Int32), io.handle, raw)

"""
    testvideo(io::IO, name::String; kwargs...)
    testvideo(name::String=; kwargs...)

Display a VideoIO named test video.

Control keys:
- `p`: pause
- `ctrl-c`: exit

kwargs:
- `fps::Real=30`
- `maxsize::Tuple = displaysize(io)`
"""
function testvideo(io::IO, name::String; kwargs...)
    vio = VideoIO.testvideo(name)
    play(io, VideoIO.openvideo(vio); kwargs...)
end
testvideo(name::String; kwargs...) = testvideo(stdout, name; kwargs...)

"""
    webcam(io::IO; kwargs...)
    webcam(; kwargs...)

Display default webcam.

Control keys:
- `p`: pause
- `ctrl-c`: exit

kwargs:
- `maxsize::Tuple = displaysize(io)``
"""
function webcam(io::IO; kwargs...)
    cam = VideoIO.opencamera()
    play(io, cam; fps=cam.framerate, stream=true, kwargs...)
end
webcam(; kwargs...) = webcam(stdout; stream=true, kwargs...)

"""
    play(v; kwargs...)
    play(io::IO, fpath::String; kwargs...)
    play(io::IO, vreader::T; kwargs...) where {T<:VideoIO.VideoReader}
    play(io::IO, framestack::Vector{Matrix{T}}; kwargs...) where {T<:Colorant}

Play a video at a filepath, a VideoIO.VideoReader object, or a framestack.

Framestacks should be vectors of images with a Colorant element type.

Control keys:
- `p`: pause
- `o`: step backward (in framestack mode)
- `[`: step forward (in framestack mode)
- `ctrl-c`: exit

kwargs:
- `fps::Real=30`
- `maxsize::Tuple = displaysize(io)`
- `stream::Bool=false` if true, don't terminate immediately if eof is reached
"""
play(v; kwargs...) = play(stdout, v; kwargs...)
play(io::IO, fpath::String; kwargs...) = play(io, VideoIO.openvideo(fpath); kwargs...)
function play(io::IO, vreader::T; fps::Real=30, maxsize::Tuple = displaysize(io), stream::Bool=false) where {T<:VideoIO.VideoReader}
    # sizing
    img = read(vreader)
    try
        seekstart(vreader)
    catch
    end
    img_w, img_h = size(img)
    io_h, io_w = maxsize
    blocks = 3img_w <= io_w ? BigBlocks() : SmallBlocks()

    # fixed
    c = ImageInTerminal.colormode[]

    # vars
    frame = 1
    paused = false
    finished = false
    first_print = true
    actual_fps = 0

    println(summary(img))
    keytask = @async begin
        try
            setraw!(stdin, true)
            while !finished
                keyin = read(stdin, Char)
                keyin == 'p' && (paused = !paused)
                keyin == '\x03' && (finished = true)
            end
        catch
        finally
            setraw!(stdin, false)
        end
    end
    try
        print(ansi_disablecursor)
        while !finished
            tim = Timer(1/fps)
            t = @elapsed begin
                if !paused && !eof(vreader)
                    VideoIO.read!(vreader, img)
                else
                    wait(tim)
                    continue
                end
                lines, rows, cols = encodeimg(blocks, c, img, io_h, io_w)
                str = sprint() do ios
                    println.((ios,), lines)
                    println(ios, "Preview: $(cols)x$(rows) FPS: $(round(actual_fps, digits=1)). Frame: $frame")
                end
                frame == 1 ? print(str) : print(ansi_moveup(rows+1), ansi_movecol1, str)
                first_print = false
                (!stream && !paused && eof(vreader)) && break
                !paused && (frame += 1)
                wait(tim)
            end
            actual_fps = 1 / t
        end
    catch e
        isa(e,InterruptException) || rethrow()
    finally
        print(ansi_enablecursor)
        finished = true
        @async Base.throwto(keytask, InterruptException())
        close(vreader)
        wait(keytask)
    end
    return
end
function play(io::IO, framestack::Vector{T}; fps::Real=30, maxsize::Tuple = displaysize(io)) where {T<:AbstractArray}
    @assert eltype(framestack[1]) <: Colorant
    # sizing
    img_w, img_h = size(framestack[1])
    io_h, io_w = maxsize
    blocks = 3img_w <= io_w ? BigBlocks() : SmallBlocks()

    # fixed
    nframes = length(framestack)
    c = ImageInTerminal.colormode[]

    # vars
    frame = 1
    paused = false
    finished = false
    first_print = true
    actual_fps = 0

    println(summary(framestack[1]))
    keytask = @async begin
        try
            setraw!(stdin, true)
            while !finished
                keyin = read(stdin, Char)
                keyin == 'p' && (paused = !paused)
                keyin == 'o' && (frame = frame <= 1 ? 1 : frame - 1)
                keyin == '[' && (frame = frame >= nframes ? nframes : frame + 1)
                keyin == '\x03' && (finished = true)
            end
        catch
        finally
            setraw!(stdin, false)
        end
    end
    try
        print(ansi_disablecursor)
        setraw!(stdin, true)
        while !finished
            tim = Timer(1/fps)
            t = @elapsed begin
                lines, rows, cols = encodeimg(blocks, c, framestack[frame], io_h, io_w)
                str = sprint() do ios
                    println.((ios,), lines)
                    println(ios, "Preview: $(cols)x$(rows) FPS: $(round(actual_fps, digits=1)). Frame: $frame/$nframes", " "^5)
                end
                first_print ? print(str) : print(ansi_moveup(rows+1), ansi_movecol1, str)
                first_print = false
                (!paused && frame == nframes) && break
                !paused && (frame += 1)
                wait(tim)
            end
            actual_fps = 1 / t
        end
    catch e
        isa(e,InterruptException) || rethrow()
    finally
        print(ansi_enablecursor)
        finished = true
        @async Base.throwto(keytask, InterruptException())
        wait(keytask)
    end
    return
end

end # module
