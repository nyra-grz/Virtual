/* Verify Windows argv round trips through the app's job/process helper. */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
int wmain(int argc, WCHAR **argv)
{
    int i, j;
    printf("ARGC=%d\n", argc - 1);
    for (i = 1; i < argc; i++)
    {
        printf("ARG%d=", i);
        for (j = 0; argv[i][j]; j++) printf("%04x", (unsigned)argv[i][j]);
        putchar('\n');
    }
    return 0;
}
