/* Decode an actual local video through Media Foundation, not just DLL loading. */
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <stdio.h>
int wmain(int argc, WCHAR **argv)
{
    IMFSourceReader *reader = NULL;
    IMFAttributes *attributes = NULL;
    IMFMediaType *type = NULL;
    IMFSample *sample = NULL;
    IMFMediaBuffer *buffer = NULL;
    DWORD stream, flags, length = 0;
    BYTE *pixels = NULL;
    int blue = 0;
    LONGLONG timestamp;
    HRESULT hr;
    int attempt;
    if (argc != 2) return 2;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (FAILED(hr)) goto failed;
    MFCreateAttributes(&attributes, 1);
    IMFAttributes_SetUINT32(attributes, &MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    hr = MFCreateSourceReaderFromURL(argv[1], attributes, &reader);
    if (FAILED(hr)) goto failed;
    printf("Media Foundation: source opened\n"); fflush(stdout);
    MFCreateMediaType(&type);
    {
        IMFMediaType *native = NULL;
        hr = IMFSourceReader_GetNativeMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &native);
        if (SUCCEEDED(hr)) { IMFMediaType_CopyAllItems(native, (IMFAttributes *)type); IMFMediaType_Release(native); }
    }
    IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, &MFVideoFormat_RGB32);
    hr = IMFSourceReader_SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, type);
    if (FAILED(hr)) goto failed;
    printf("Media Foundation: output type selected\n"); fflush(stdout);
    for (attempt = 0; attempt < 30; attempt++)
    {
        hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &stream, &flags, &timestamp, &sample);
        if (FAILED(hr)) goto failed;
        if (sample) break;
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    if (!sample) { hr = E_FAIL; goto failed; }
    hr = IMFSample_ConvertToContiguousBuffer(sample, &buffer);
    if (FAILED(hr)) goto failed;
    IMFMediaBuffer_GetCurrentLength(buffer, &length);
    if (SUCCEEDED(IMFMediaBuffer_Lock(buffer, &pixels, NULL, NULL)))
    {
        blue = length >= 4 && pixels[0] > 180 && pixels[1] < 60 && pixels[2] < 60;
        IMFMediaBuffer_Unlock(buffer);
    }
    printf("Media Foundation: RGB32 sample=%lu bytes timestamp=%lld decoded-blue=%d\n", length, timestamp, blue);
    fflush(stdout);
    IMFMediaBuffer_Release(buffer); IMFSample_Release(sample);
    IMFMediaType_Release(type); IMFSourceReader_Release(reader); IMFAttributes_Release(attributes);
    MFShutdown(); CoUninitialize();
    return length && blue ? 0 : 3;
failed:
    printf("Media Foundation failed: %08lx\n", (unsigned long)hr);
    return 1;
}
