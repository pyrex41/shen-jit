/* Reading and loading stage 0 text. */
#ifndef SJ_READER_H
#define SJ_READER_H

#include "vm.h"

typedef struct {
    VM *vm;
    const char *p, *end;
    const char *error;
    bool kl; /* KLambda source rather than stage 0 text: c#NN; string escapes,
                and decimals with a zero fraction read as integers, as the
                Shen reader computes them */
} Reader;

/* Reads one value; returns V_CLEARED and sets error on failure. The text must
   be outside the heap. */
V reader_read(Reader *r);
bool reader_at_end(Reader *r);

typedef struct {
    size_t defuns;
    size_t codes;
    size_t instructions;
    size_t bytecode_bytes;
    size_t constants;
} LoadStats;

/* Loads a sequence of (defun Name Code) forms, installing each as Name's
   function, then binds sealed calls to the definitions loaded so far.
   Returns false with a message on malformed input. */
bool load_stage0(VM *vm, const char *text, size_t len, LoadStats *stats, const char **error);
bool load_stage0_sealed(VM *vm, const char *text, size_t len, size_t seal_until, LoadStats *stats,
                        const char **error);

/* Installs lowered code at runtime; raises on malformed input. */
V sj_install(VM *vm, V form);

#endif
