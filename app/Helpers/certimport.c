/* certimport.exe – imports certificates into the current user's Windows certificate stores.
 * Built by build-app.sh with mingw-w64 and bundled into Virtual.app; Virtual runs it inside a room.
 *
 *   certimport.exe <file>      (.cer/.crt/.der/.pem/.p7b, or .pfx/.p12 with the password on stdin)
 *
 * Self-signed certificates go to "Root" (trusted roots), other certificates to "CA", and
 * certificates with a private key from a PFX file to "My". Prints one line per certificate.
 */
#include <windows.h>
#include <wincrypt.h>
#include <stdio.h>
#include <string.h>

static void print_utf8(const WCHAR *text)
{
    char buf[1024];
    int n = WideCharToMultiByte(CP_UTF8, 0, text, -1, buf, sizeof(buf), NULL, NULL);
    if (n > 1) fwrite(buf, 1, n - 1, stdout);
}

static BOOL add_to_store(PCCERT_CONTEXT cert, const WCHAR *store_name)
{
    HCERTSTORE store = CertOpenStore(CERT_STORE_PROV_SYSTEM_W, 0, 0, CERT_SYSTEM_STORE_CURRENT_USER, store_name);
    WCHAR name[256] = L"?", line[512];
    BOOL ok;

    if (!store) return FALSE;
    ok = CertAddCertificateContextToStore(store, cert, CERT_STORE_ADD_REPLACE_EXISTING, NULL);
    CertCloseStore(store, 0);
    CertGetNameStringW(cert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, NULL, name, ARRAYSIZE(name));
    swprintf(line, ARRAYSIZE(line), L"%ls: %ls\n", ok ? (wcscmp(store_name, L"Root") ? (wcscmp(store_name, L"My") ? L"Zwischenzertifikat" : L"Eigenes Zertifikat") : L"Vertrauenswürdige Stammzertifizierungsstelle") : L"Fehler", name);
    print_utf8(line);
    return ok;
}

static int import_store(HCERTSTORE source, BOOL from_pfx)
{
    PCCERT_CONTEXT cert = NULL;
    int count = 0;
    DWORD size;

    while ((cert = CertEnumCertificatesInStore(source, cert)))
    {
        const WCHAR *target;
        if (from_pfx && CertGetCertificateContextProperty(cert, CERT_KEY_PROV_INFO_PROP_ID, NULL, &size)) target = L"My";
        else if (CertCompareCertificateName(X509_ASN_ENCODING, &cert->pCertInfo->Subject, &cert->pCertInfo->Issuer)) target = L"Root";
        else target = L"CA";
        if (add_to_store(cert, target)) count++;
    }
    return count;
}

int wmain(int argc, WCHAR **argv)
{
    HANDLE file;
    DWORD size, read;
    BYTE *data;
    CRYPT_DATA_BLOB blob;
    HCERTSTORE store = NULL;
    int count = 0;

    if (argc != 2)
    {
        fputs("Aufruf: certimport.exe <Datei>\n", stdout);
        return 2;
    }
    file = CreateFileW(argv[1], GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE)
    {
        fputs("Datei nicht lesbar.\n", stdout);
        return 1;
    }
    size = GetFileSize(file, NULL);
    data = malloc(size + 1);
    if (!data || !ReadFile(file, data, size, &read, NULL) || read != size)
    {
        CloseHandle(file);
        fputs("Datei nicht lesbar.\n", stdout);
        return 1;
    }
    CloseHandle(file);
    data[size] = 0;
    blob.cbData = size;
    blob.pbData = data;

    if (PFXIsPFXBlob(&blob))
    {
        char password[256] = "";
        WCHAR wpassword[256];
        if (fgets(password, sizeof(password), stdin)) password[strcspn(password, "\r\n")] = 0;
        MultiByteToWideChar(CP_UTF8, 0, password, -1, wpassword, ARRAYSIZE(wpassword));
        store = PFXImportCertStore(&blob, wpassword, CRYPT_USER_KEYSET);
        SecureZeroMemory(password, sizeof(password));
        SecureZeroMemory(wpassword, sizeof(wpassword));
        if (!store)
        {
            fputs("Falsches Passwort oder beschädigte Datei.\n", stdout);
            return 1;
        }
        count = import_store(store, TRUE);
    }
    else if (!strncmp((char *)data, "-----BEGIN", 10))
    {
        /* PEM: every "-----BEGIN CERTIFICATE-----" block is one certificate. */
        char *p = (char *)data;
        store = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, NULL);
        while (store && (p = strstr(p, "-----BEGIN")))
        {
            char *end = strstr(p, "-----END");
            DWORD der_size = 0;
            BYTE *der;
            if (!end) break;
            end = strchr(end + 8, '\n') ? strchr(end + 8, '\n') : end + strlen(end);
            if (CryptStringToBinaryA(p, end - p, CRYPT_STRING_BASE64HEADER, NULL, &der_size, NULL, NULL) &&
                (der = malloc(der_size)))
            {
                if (CryptStringToBinaryA(p, end - p, CRYPT_STRING_BASE64HEADER, der, &der_size, NULL, NULL))
                    CertAddEncodedCertificateToStore(store, X509_ASN_ENCODING, der, der_size, CERT_STORE_ADD_ALWAYS, NULL);
                free(der);
            }
            p = end;
        }
        if (store) count = import_store(store, FALSE);
    }
    else if (CryptQueryObject(CERT_QUERY_OBJECT_BLOB, &blob, CERT_QUERY_CONTENT_FLAG_ALL, CERT_QUERY_FORMAT_FLAG_ALL, 0,
                              NULL, NULL, NULL, &store, NULL, NULL) && store)
    {
        count = import_store(store, FALSE);
    }

    if (store) CertCloseStore(store, 0);
    free(data);
    if (!count)
    {
        fputs("Keine Zertifikate gefunden oder importiert.\n", stdout);
        return 1;
    }
    return 0;
}
