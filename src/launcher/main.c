#include "document/c_api.h"
#include "indentation/c_api.h"
#include "runtime/c_api.h"
#include "syntax/c_api.h"
#include "tree_sitter/c_api.h"

#define SCHEME_STATIC
#include <scheme.h>

#include <stdio.h>
#include <string.h>

extern unsigned char soda_petite_boot[];
extern unsigned int soda_petite_boot_len;
extern unsigned char soda_scheme_boot[];
extern unsigned int soda_scheme_boot_len;
extern unsigned char soda_core_boot[];
extern unsigned int soda_core_boot_len;

static int soda_embedded_native(void) {
    return 1;
}

static void register_soda_foreign_symbols(void) {
    Sforeign_symbol("soda_embedded_native", (void*)soda_embedded_native);
#define SODA_FOREIGN_SYMBOL(symbol) Sforeign_symbol(#symbol, (void*)(symbol));
#include "soda_foreign_symbols.inc"
#undef SODA_FOREIGN_SYMBOL
}

int main(int argc, char* argv[]) {
    if (strcmp(Skernel_version(), VERSION) != 0) {
        fputs("soda: Chez kernel version ", stderr);
        fputs(Skernel_version(), stderr);
        fputs(" does not match headers for ", stderr);
        fputs(VERSION, stderr);
        fputc('\n', stderr);
        return 1;
    }

    Sscheme_init(NULL);
    Sregister_boot_file_bytes("petite.boot", soda_petite_boot, (iptr)soda_petite_boot_len);
    Sregister_boot_file_bytes("scheme.boot", soda_scheme_boot, (iptr)soda_scheme_boot_len);
    Sregister_boot_file_bytes("soda-core.boot", soda_core_boot, (iptr)soda_core_boot_len);
    Sbuild_heap(NULL, register_soda_foreign_symbols);
    Scall1(Stop_level_value(Sstring_to_symbol("suppress-greeting")), Strue);

    const int status = Sscheme_start(argc, (const char**)argv);
    Sscheme_deinit();
    return status;
}
