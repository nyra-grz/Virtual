/* Checks IAudioEndpointVolume on the default render and capture devices: real channel
 * count, master/channel levels with balance, mute, steps, change notifications and that
 * a second process sees the same volume. Restores the previous volume and exits with 1
 * on any failure.
 *
 *   x86_64-w64-mingw32-gcc winrt/tests/audio.c -o build/audio.exe -lole32 -luuid
 *   runtime/bin/virtual build/audio.exe
 */
#define COBJMACROS
#define INITGUID
#include <stdio.h>
#include <math.h>
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <endpointvolume.h>

static int failures, checks;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; \
    printf("FAIL line %d: %s – ", __LINE__, #cond); printf(__VA_ARGS__); printf("\n"); } } while (0)

static BOOL close_to(float a, float b) { return fabsf(a - b) < 0.01f; }

static const GUID test_context = { 0x5a1e7c3d, 0x2b4f, 0x4c6a, { 0x9e, 0x11, 0x0d, 0x7a, 0x3c, 0x55, 0x81, 0x42 } };

struct callback {
    IAudioEndpointVolumeCallback iface;
    LONG ref, calls;
    GUID context;
    float master;
    BOOL muted;
    UINT channels;
    DWORD thread;
};

static struct callback *impl(IAudioEndpointVolumeCallback *iface) { return CONTAINING_RECORD(iface, struct callback, iface); }

static HRESULT WINAPI cb_QueryInterface(IAudioEndpointVolumeCallback *iface, REFIID riid, void **out)
{
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IAudioEndpointVolumeCallback)) {
        *out = iface;
        IAudioEndpointVolumeCallback_AddRef(iface);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG WINAPI cb_AddRef(IAudioEndpointVolumeCallback *iface) { return InterlockedIncrement(&impl(iface)->ref); }
static ULONG WINAPI cb_Release(IAudioEndpointVolumeCallback *iface) { return InterlockedDecrement(&impl(iface)->ref); }
static HRESULT WINAPI cb_OnNotify(IAudioEndpointVolumeCallback *iface, AUDIO_VOLUME_NOTIFICATION_DATA *data)
{
    struct callback *cb = impl(iface);
    cb->context = data->guidEventContext;
    cb->master = data->fMasterVolume;
    cb->muted = data->bMuted;
    cb->channels = data->nChannels;
    cb->thread = GetCurrentThreadId();
    InterlockedIncrement(&cb->calls);
    return S_OK;
}
static IAudioEndpointVolumeCallbackVtbl cb_vtbl = { cb_QueryInterface, cb_AddRef, cb_Release, cb_OnNotify };

static BOOL wait_calls(struct callback *cb, LONG calls)
{
    int i;
    for (i = 0; i < 100 && cb->calls < calls; i++) Sleep(10);
    return cb->calls >= calls;
}

static float child_master(EDataFlow flow)
{
    char cmd[MAX_PATH + 32], path[MAX_PATH];
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DWORD code = 0;

    GetModuleFileNameA(NULL, path, sizeof(path));
    sprintf(cmd, "\"%s\" child %d", path, flow);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) return -1.0f;
    WaitForSingleObject(pi.hProcess, 20000);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return code / 1000.0f;
}

static IMMDevice *default_device(EDataFlow flow)
{
    IMMDeviceEnumerator *devices;
    IMMDevice *device = NULL;

    if (FAILED(CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_INPROC_SERVER,
                                &IID_IMMDeviceEnumerator, (void **)&devices))) return NULL;
    IMMDeviceEnumerator_GetDefaultAudioEndpoint(devices, flow, eConsole, &device);
    IMMDeviceEnumerator_Release(devices);
    return device;
}

static void test_device(EDataFlow flow)
{
    const char *name = flow == eRender ? "render" : "capture";
    struct callback cb = { { &cb_vtbl }, 1 };
    IAudioEndpointVolume *volume;
    IAudioEndpointVolumeEx *volume_ex;
    IAudioClient *client;
    DWORD support;
    WAVEFORMATEX *fmt;
    float old_levels[32], level, min_db, max_db, inc, other;
    UINT channels = 0, i, step, steps;
    BOOL old_mute, mute;
    LONG calls;
    HRESULT hr;
    IMMDevice *device = default_device(flow);

    if (!device) { printf("%s: no device, skipped\n", name); return; }
    hr = IMMDevice_Activate(device, &IID_IAudioEndpointVolume, CLSCTX_INPROC_SERVER, NULL, (void **)&volume);
    CHECK(hr == S_OK, "%s Activate %#lx", name, hr);
    if (FAILED(hr)) return;

    hr = IAudioEndpointVolume_GetChannelCount(volume, &channels);
    CHECK(hr == S_OK && channels > 0, "%s GetChannelCount %#lx %u", name, hr, channels);
    if (SUCCEEDED(IMMDevice_Activate(device, &IID_IAudioClient, CLSCTX_INPROC_SERVER, NULL, (void **)&client))) {
        if (SUCCEEDED(IAudioClient_GetMixFormat(client, &fmt))) {
            CHECK(channels == fmt->nChannels, "%s channels %u, mix format %u", name, channels, fmt->nChannels);
            CoTaskMemFree(fmt);
        }
        IAudioClient_Release(client);
    }
    printf("%s: %u channels\n", name, channels);
    if (channels > 32) channels = 32;
    CHECK(IAudioEndpointVolume_GetChannelCount(volume, NULL) == E_POINTER, "%s GetChannelCount(NULL)", name);

    for (i = 0; i < channels; i++) IAudioEndpointVolume_GetChannelVolumeLevel(volume, i, &old_levels[i]);
    IAudioEndpointVolume_GetMute(volume, &old_mute);

    hr = IAudioEndpointVolume_GetVolumeRange(volume, &min_db, &max_db, &inc);
    CHECK(hr == S_OK && min_db < max_db && inc > 0, "%s GetVolumeRange %#lx", name, hr);
    hr = IAudioEndpointVolume_QueryInterface(volume, &IID_IAudioEndpointVolumeEx, (void **)&volume_ex);
    CHECK(hr == S_OK, "%s IAudioEndpointVolumeEx %#lx", name, hr);
    if (SUCCEEDED(hr)) {
        hr = IAudioEndpointVolumeEx_GetVolumeRangeChannel(volume_ex, 0, &min_db, &max_db, &inc);
        CHECK(hr == S_OK, "%s GetVolumeRangeChannel %#lx", name, hr);
        hr = IAudioEndpointVolumeEx_GetVolumeRangeChannel(volume_ex, channels, &min_db, &max_db, &inc);
        CHECK(hr == E_INVALIDARG, "%s GetVolumeRangeChannel out of range %#lx", name, hr);
        IAudioEndpointVolumeEx_Release(volume_ex);
    }

    hr = IAudioEndpointVolume_RegisterControlChangeNotify(volume, &cb.iface);
    CHECK(hr == S_OK, "%s Register %#lx", name, hr);

    hr = IAudioEndpointVolume_SetMasterVolumeLevelScalar(volume, 0.5f, &test_context);
    CHECK(hr == S_OK, "%s SetMasterVolumeLevelScalar %#lx", name, hr);
    IAudioEndpointVolume_GetMasterVolumeLevelScalar(volume, &level);
    CHECK(close_to(level, 0.5f), "%s master scalar %f", name, level);
    IAudioEndpointVolume_GetMasterVolumeLevel(volume, &level);
    CHECK(fabsf(level - 20.0f * log10f(0.5f)) < 0.05f, "%s master dB %f", name, level);
    CHECK(wait_calls(&cb, 1), "%s no notification", name);
    CHECK(IsEqualGUID(&cb.context, &test_context), "%s notification context", name);
    CHECK(close_to(cb.master, 0.5f) && cb.channels == channels, "%s notification %f %u", name, cb.master, cb.channels);
    CHECK(cb.thread && cb.thread != GetCurrentThreadId(), "%s notification on the caller's thread", name);

    other = child_master(flow);
    CHECK(close_to(other, 0.5f), "%s other process sees %f", name, other);

    hr = IAudioEndpointVolume_SetMasterVolumeLevel(volume, 0.0f, NULL);
    CHECK(hr == S_OK, "%s SetMasterVolumeLevel %#lx", name, hr);
    if (channels >= 2) {
        hr = IAudioEndpointVolume_SetChannelVolumeLevelScalar(volume, 1, 0.25f, NULL);
        CHECK(hr == S_OK, "%s SetChannelVolumeLevelScalar %#lx", name, hr);
        IAudioEndpointVolume_GetChannelVolumeLevelScalar(volume, 1, &level);
        CHECK(close_to(level, 0.25f), "%s channel 1 %f", name, level);
        IAudioEndpointVolume_GetMasterVolumeLevelScalar(volume, &level);
        CHECK(close_to(level, 1.0f), "%s master follows loudest channel %f", name, level);
        /* Halving the master keeps the balance. */
        IAudioEndpointVolume_SetMasterVolumeLevelScalar(volume, 0.5f, NULL);
        IAudioEndpointVolume_GetChannelVolumeLevelScalar(volume, 0, &level);
        CHECK(close_to(level, 0.5f), "%s channel 0 after master %f", name, level);
        IAudioEndpointVolume_GetChannelVolumeLevelScalar(volume, 1, &level);
        CHECK(close_to(level, 0.125f), "%s channel 1 after master %f", name, level);
    }
    hr = IAudioEndpointVolume_SetChannelVolumeLevel(volume, channels, -10.0f, NULL);
    CHECK(hr == E_INVALIDARG, "%s channel out of range %#lx", name, hr);
    hr = IAudioEndpointVolume_GetChannelVolumeLevel(volume, channels, &level);
    CHECK(hr == E_INVALIDARG, "%s get channel out of range %#lx", name, hr);
    hr = IAudioEndpointVolume_SetMasterVolumeLevelScalar(volume, 1.5f, NULL);
    CHECK(hr == E_INVALIDARG, "%s scalar 1.5 %#lx", name, hr);
    hr = IAudioEndpointVolume_SetMasterVolumeLevel(volume, max_db + 5.0f, NULL);
    CHECK(hr == E_INVALIDARG, "%s dB above max %#lx", name, hr);

    IAudioEndpointVolume_SetMasterVolumeLevelScalar(volume, 0.5f, NULL);
    hr = IAudioEndpointVolume_GetVolumeStepInfo(volume, &step, &steps);
    CHECK(hr == S_OK && steps > 1 && step < steps, "%s GetVolumeStepInfo %#lx %u/%u", name, hr, step, steps);
    hr = IAudioEndpointVolume_VolumeStepUp(volume, NULL);
    CHECK(hr == S_OK, "%s VolumeStepUp %#lx", name, hr);
    IAudioEndpointVolume_GetVolumeStepInfo(volume, &i, NULL);
    CHECK(i == step + 1, "%s step after up %u, before %u", name, i, step);
    IAudioEndpointVolume_VolumeStepDown(volume, NULL);
    IAudioEndpointVolume_VolumeStepDown(volume, NULL);
    IAudioEndpointVolume_GetVolumeStepInfo(volume, &i, NULL);
    CHECK(i == step - 1, "%s step after down %u, before %u", name, i, step);

    IAudioEndpointVolume_SetMute(volume, FALSE, NULL);
    calls = cb.calls;
    hr = IAudioEndpointVolume_SetMute(volume, TRUE, &test_context);
    CHECK(hr == S_OK, "%s SetMute %#lx", name, hr);
    hr = IAudioEndpointVolume_SetMute(volume, TRUE, NULL);
    CHECK(hr == S_FALSE, "%s SetMute again %#lx", name, hr);
    IAudioEndpointVolume_GetMute(volume, &mute);
    CHECK(mute, "%s GetMute", name);
    CHECK(wait_calls(&cb, calls + 1) && cb.muted, "%s mute notification", name);

    hr = IAudioEndpointVolume_QueryHardwareSupport(volume, &support);
    CHECK(hr == S_OK, "%s QueryHardwareSupport %#lx", name, hr);

    hr = IAudioEndpointVolume_UnregisterControlChangeNotify(volume, &cb.iface);
    CHECK(hr == S_OK, "%s Unregister %#lx", name, hr);
    calls = cb.calls;
    IAudioEndpointVolume_SetMute(volume, FALSE, NULL);
    Sleep(100);
    CHECK(cb.calls == calls, "%s notified after Unregister", name);
    CHECK(cb.ref == 1, "%s callback ref %ld", name, cb.ref);

    for (i = 0; i < channels; i++) IAudioEndpointVolume_SetChannelVolumeLevel(volume, i, old_levels[i], NULL);
    IAudioEndpointVolume_SetMute(volume, old_mute, NULL);
    IAudioEndpointVolume_Release(volume);
    IMMDevice_Release(device);
}

int main(int argc, char **argv)
{
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (argc == 3 && !strcmp(argv[1], "child")) {
        IMMDevice *device = default_device(atoi(argv[2]));
        IAudioEndpointVolume *volume;
        float level = -1.0f;
        if (device && SUCCEEDED(IMMDevice_Activate(device, &IID_IAudioEndpointVolume, CLSCTX_INPROC_SERVER, NULL, (void **)&volume)))
            IAudioEndpointVolume_GetMasterVolumeLevelScalar(volume, &level);
        return (int)lroundf(level * 1000.0f);
    }
    test_device(eRender);
    test_device(eCapture);
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
