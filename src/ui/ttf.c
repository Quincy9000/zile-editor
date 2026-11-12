// Glyphs by glyph id (ligatures substitute glyphs no codepoint maps to):
// raylib's copy of stb_truetype is private to it (STBTT_STATIC), so zile
// compiles its own, behind these few calls.
#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "stb_truetype.h"
#include <stdlib.h>

typedef struct {
    stbtt_fontinfo info;
    float scale;
    int ascent;
} ZileTtf;

// `data` must outlive the handle. Scaled as raylib's LoadFontEx does.
ZileTtf *zile_ttf_open(const unsigned char *data, int pixel_height) {
    ZileTtf *f = malloc(sizeof *f);
    if (!f) return NULL;
    if (!stbtt_InitFont(&f->info, data, stbtt_GetFontOffsetForIndex(data, 0))) {
        free(f);
        return NULL;
    }
    f->scale = stbtt_ScaleForPixelHeight(&f->info, (float)pixel_height);
    int descent, gap;
    stbtt_GetFontVMetrics(&f->info, &f->ascent, &descent, &gap);
    return f;
}

void zile_ttf_close(ZileTtf *f) { free(f); }

int zile_ttf_glyph(const ZileTtf *f, int codepoint) { return stbtt_FindGlyphIndex(&f->info, codepoint); }

// An 8-bit coverage bitmap of `glyph` (NULL for an empty one), placed as
// raylib places a codepoint's: `xoff` from the pen, `yoff` from the line's
// top. Freed with zile_ttf_free.
unsigned char *zile_ttf_bitmap(const ZileTtf *f, int glyph, int *w, int *h, int *xoff, int *yoff) {
    unsigned char *b = stbtt_GetGlyphBitmap(&f->info, f->scale, f->scale, glyph, w, h, xoff, yoff);
    *yoff += (int)((float)f->ascent * f->scale);
    return b;
}

void zile_ttf_free(unsigned char *b) { free(b); }
