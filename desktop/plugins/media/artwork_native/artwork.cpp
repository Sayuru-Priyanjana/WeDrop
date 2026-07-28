// Extracts the current System Media Transport Controls session's album art
// as a small JPEG, exported as a plain C ABI so the Go plugin can load this
// as a DLL and call it via syscall — no cgo involved (cgo on Windows expects
// a gcc-compatible compiler, and C++/WinRT needs MSVC, so the two don't mix;
// see artwork_windows.go for how this is loaded).
//
// Every call here is a real, safe, compiler-checked C++/WinRT projection call
// (the same API surface KDE Connect's own Windows mpriscontrol plugin uses:
// TryGetMediaPropertiesAsync -> Thumbnail -> OpenReadAsync), not a hand-rolled
// COM vtable/GUID — the whole point of building this as a native helper
// instead of doing it in raw Go was to avoid exactly that kind of unverified
// vtable work.
//
// The source thumbnail can be any format the player provides (JPEG, PNG,
// BMP...); this always decodes it and re-encodes explicitly as JPEG via
// BitmapEncoder::CreateAsync(BitmapEncoder::JpegEncoderId(), ...), so the
// output format is guaranteed regardless of the source, matching what the
// wire protocol and both clients (React <img>, Flutter Image.memory) expect.
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Graphics.Imaging.h>

#include <cstdlib>
#include <cstring>
#include <cstdint>

using namespace winrt;
using namespace winrt::Windows::Media::Control;
using namespace winrt::Windows::Storage::Streams;
using namespace winrt::Windows::Graphics::Imaging;

namespace {

// Matches the mobile side's own cap (MediaSessionTracker.kt), so a preview
// from either platform stays comfortably inside a single network frame.
constexpr uint32_t kMaxDim = 200;

} // namespace

extern "C" __declspec(dllexport) int WedropGetArtworkJpeg(unsigned char **outData, unsigned int *outLen) {
    *outData = nullptr;
    *outLen = 0;

    try {
        init_apartment(apartment_type::multi_threaded);
    } catch (...) {
        // Already initialized on this thread (possibly with a different but
        // compatible model from an earlier call) — nothing to do.
    }

    try {
        auto mgr = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
        auto session = mgr.GetCurrentSession();
        if (!session) {
            return 1; // nothing is playing anywhere
        }

        auto props = session.TryGetMediaPropertiesAsync().get();
        auto thumbRef = props.Thumbnail();
        if (!thumbRef) {
            return 2; // this source has no artwork
        }

        auto srcStream = thumbRef.OpenReadAsync().get();
        if (!srcStream || !srcStream.CanRead()) {
            return 3;
        }

        auto decoder = BitmapDecoder::CreateAsync(srcStream).get();
        auto softwareBitmap = decoder.GetSoftwareBitmapAsync().get();

        uint32_t width = decoder.PixelWidth();
        uint32_t height = decoder.PixelHeight();
        uint32_t targetW = width;
        uint32_t targetH = height;
        if (width > kMaxDim || height > kMaxDim) {
            double scale = (double)kMaxDim / (double)(width > height ? width : height);
            targetW = (uint32_t)(width * scale);
            targetH = (uint32_t)(height * scale);
            if (targetW < 1) targetW = 1;
            if (targetH < 1) targetH = 1;
        }

        InMemoryRandomAccessStream outStream;
        auto encoder = BitmapEncoder::CreateAsync(BitmapEncoder::JpegEncoderId(), outStream).get();
        encoder.SetSoftwareBitmap(softwareBitmap);
        encoder.BitmapTransform().ScaledWidth(targetW);
        encoder.BitmapTransform().ScaledHeight(targetH);
        encoder.BitmapTransform().InterpolationMode(BitmapInterpolationMode::Fant);
        encoder.FlushAsync().get();

        outStream.Seek(0);
        uint32_t size = (uint32_t)outStream.Size();
        if (size == 0) {
            return 4;
        }

        Buffer initialBuffer(size);
        IBuffer buffer = outStream.ReadAsync(initialBuffer, size, InputStreamOptions::None).get();

        unsigned char *heapBuf = (unsigned char *)malloc(buffer.Length());
        if (!heapBuf) {
            return 5;
        }
        memcpy(heapBuf, buffer.data(), buffer.Length());

        *outData = heapBuf;
        *outLen = buffer.Length();
        return 0;
    } catch (const hresult_error &) {
        return 6;
    } catch (...) {
        return 7;
    }
}

extern "C" __declspec(dllexport) void WedropFreeArtwork(unsigned char *data) {
    if (data) {
        free(data);
    }
}
