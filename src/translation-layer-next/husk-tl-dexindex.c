/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "husk-tl-dexindex.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "husk-tl-bionic.h"
#include "husk-tl-internal.h"
#include "husk-tl-ld.h"

typedef struct {
    const uint8_t *d;
    size_t size;
    uint32_t nstr, str_off, ntype, type_off, nproto, proto_off, nfield, field_off, nmeth, meth_off, nclass, class_off;
} dexfile;

typedef struct { int dex; uint32_t def; } cls_ref;

enum {
    TL_DEXIDX_MAX_DEX_FILES = TL_LD_MAX_APKS * 16,
    TL_DEXIDX_MAX_BYTES = 256u << 20,
    TL_DEXIDX_MAX_CLASSES = 1u << 20,
    TL_DEXIDX_MAX_STRINGS = 16u << 20,
};

typedef struct { uint32_t number; const tl_zip_entry *entry; } dex_entry;

static dexfile g_dex[TL_DEXIDX_MAX_DEX_FILES];
static int g_ndex;
static cls_ref *g_tab;           /* open-addressed by hash of the descriptor */
static size_t g_tab_n;
static int g_classes;
static pthread_rwlock_t g_dex_lock = PTHREAD_RWLOCK_INITIALIZER;
static _Thread_local unsigned g_dex_read_depth;

static void dex_read_lock(void)
{
    if (g_dex_read_depth++ == 0) pthread_rwlock_rdlock(&g_dex_lock);
}

static void dex_read_unlock(void)
{
    if (g_dex_read_depth && --g_dex_read_depth == 0) pthread_rwlock_unlock(&g_dex_lock);
}

static uint32_t u32(const dexfile *x, size_t o) { uint32_t v; memcpy(&v, x->d + o, 4); return v; }
static uint16_t u16(const dexfile *x, size_t o) { uint16_t v; memcpy(&v, x->d + o, 2); return v; }
static uint32_t raw_u32(const uint8_t *d, size_t o) { uint32_t v; memcpy(&v, d + o, 4); return v; }

static bool dex_entry_number(const char *name, uint32_t *number)
{
    if (!strcmp(name, "classes.dex")) { *number = 1; return true; }
    if (strncmp(name, "classes", 7) || name[7] < '1' || name[7] > '9') return false;
    const char *p = name + 7;
    uint32_t value = 0;
    while (*p >= '0' && *p <= '9') {
        unsigned digit = (unsigned)(*p++ - '0');
        if (value > (UINT32_MAX - digit) / 10) return false;
        value = value * 10 + digit;
    }
    if (value < 2 || strcmp(p, ".dex")) return false;
    *number = value;
    return true;
}

static int compare_dex_entries(const void *a, const void *b)
{
    const dex_entry *x = a, *y = b;
    return x->number < y->number ? -1 : x->number > y->number ? 1 : 0;
}

static bool table_fits(size_t len, uint32_t off, uint32_t count, size_t item_size)
{
    return count == 0 || (off >= 0x70 && off <= len && count <= (len - off) / item_size);
}

static bool read_uleb(const dexfile *x, size_t *o, uint32_t *value)
{
    uint32_t result = 0;
    for (unsigned shift = 0; shift < 35; shift += 7) {
        if (*o >= x->size) return false;
        uint8_t b = x->d[(*o)++];
        if (shift == 28 && (b & 0xf0)) return false;
        result |= (uint32_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) { *value = result; return true; }
    }
    return false;
}

static uint32_t uleb(const dexfile *x, size_t *o)
{
    uint32_t r = 0; unsigned sh = 0;
    for (;;) { uint8_t b = x->d[(*o)++]; r |= (uint32_t)(b & 0x7f) << sh; if (!(b & 0x80)) break; sh += 7; }
    return r;
}

/* The UTF-8 bytes of string_ids[i], NUL-terminated inside the dex. */
static const char *str_of(const dexfile *x, uint32_t i)
{
    size_t o = u32(x, x->str_off + 4 * (size_t)i);
    uleb(x, &o);
    return (const char *)x->d + o;
}
static const char *type_of(const dexfile *x, uint32_t t) { return str_of(x, u32(x, x->type_off + 4 * (size_t)t)); }

/* "Lcom/a/B;" -> "com/a/B" (compared in place; no copy). */
static bool desc_eq(const char *desc, const char *name)
{
    size_t n = strlen(name);
    return desc[0] == 'L' && !strncmp(desc + 1, name, n) && desc[1 + n] == ';' && desc[2 + n] == 0;
}

static uint64_t hash_name(const char *s, size_t n)
{
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) { h ^= (unsigned char)s[i]; h *= 1099511628211ull; }
    return h;
}

static uint64_t hash_desc(const char *desc) { return hash_name(desc + 1, strlen(desc) - 2); }

static void insert(int dex, uint32_t def, const char *desc)
{
    size_t i = hash_desc(desc) & (g_tab_n - 1);
    while (g_tab[i].dex) i = (i + 1) & (g_tab_n - 1);
    g_tab[i].dex = dex + 1;
    g_tab[i].def = def;
}

static bool valid_string(const dexfile *x, uint32_t index, size_t *scanned)
{
    if (index >= x->nstr) return false;
    size_t id = (size_t)x->str_off + 4u * index;
    uint32_t off = u32(x, id), utf16_size;
    if (off < 0x70 || off >= x->size) return false;
    size_t p = off;
    if (!read_uleb(x, &p, &utf16_size)) return false;
    (void)utf16_size;
    if (*scanned >= x->size) return false;
    size_t budget = x->size - *scanned;
    size_t remaining = x->size - p;
    size_t scan = remaining < budget ? remaining : budget;
    const uint8_t *end = memchr(x->d + p, 0, scan);
    if (!end) return false;
    size_t bytes = (size_t)(end - (x->d + p)) + 1;
    *scanned += bytes;
    return true;
}

static bool valid_type(const dexfile *x, uint32_t index)
{
    return index < x->ntype && u32(x, (size_t)x->type_off + 4u * index) < x->nstr;
}

static bool valid_type_list(const dexfile *x, uint32_t off)
{
    if (!off) return true;
    if (off < 0x70 || off > x->size || x->size - off < 4) return false;
    uint32_t count = u32(x, off);
    if (count > (x->size - off - 4) / 2) return false;
    for (uint32_t i = 0; i < count; i++)
        if (u16(x, (size_t)off + 4u + 2u * i) >= x->ntype) return false;
    return true;
}

static bool valid_class_data(const dexfile *x, uint32_t off)
{
    if (!off) return true;
    if (off < 0x70 || off >= x->size) return false;
    size_t p = off;
    uint32_t counts[4];
    for (int i = 0; i < 4; i++) if (!read_uleb(x, &p, &counts[i])) return false;
    if (counts[0] > x->nfield || counts[1] > x->nfield ||
        counts[2] > x->nmeth || counts[3] > x->nmeth) return false;
    for (int group = 0; group < 4; group++) {
        uint32_t index = 0, limit = group < 2 ? x->nfield : x->nmeth;
        for (uint32_t i = 0; i < counts[group]; i++) {
            uint32_t delta, flags;
            if (!read_uleb(x, &p, &delta) || UINT32_MAX - index < delta) return false;
            index += delta;
            if (index >= limit || !read_uleb(x, &p, &flags)) return false;
            if (group >= 2) {
                uint32_t code_off;
                if (!read_uleb(x, &p, &code_off)) return false;
            }
        }
    }
    return true;
}

static bool validate_dex(const dexfile *x)
{
    if (x->ntype > 65536 || x->nproto > 65536 || x->nfield > 65536 || x->nmeth > 65536) return false;
    size_t scanned_strings = 0;
    for (uint32_t i = 0; i < x->nstr; i++) if (!valid_string(x, i, &scanned_strings)) return false;
    for (uint32_t i = 0; i < x->ntype; i++) if (!valid_type(x, i)) return false;
    for (uint32_t i = 0; i < x->nproto; i++) {
        size_t off = (size_t)x->proto_off + 12u * i;
        if (u32(x, off) >= x->nstr || !valid_type(x, u32(x, off + 4)) ||
            !valid_type_list(x, u32(x, off + 8))) return false;
    }
    for (uint32_t i = 0; i < x->nfield; i++) {
        size_t off = (size_t)x->field_off + 8u * i;
        if (u16(x, off) >= x->ntype || u16(x, off + 2) >= x->ntype || u32(x, off + 4) >= x->nstr) return false;
    }
    for (uint32_t i = 0; i < x->nmeth; i++) {
        size_t off = (size_t)x->meth_off + 8u * i;
        if (u16(x, off) >= x->ntype || u16(x, off + 2) >= x->nproto || u32(x, off + 4) >= x->nstr) return false;
    }
    for (uint32_t i = 0; i < x->nclass; i++) {
        size_t off = (size_t)x->class_off + 32u * i;
        uint32_t class_type = u32(x, off), superclass = u32(x, off + 8);
        if (!valid_type(x, class_type) || (superclass != 0xffffffffu && !valid_type(x, superclass)) ||
            !valid_type_list(x, u32(x, off + 12)) ||
            (u32(x, off + 16) != 0xffffffffu && u32(x, off + 16) >= x->nstr) ||
            !valid_class_data(x, u32(x, off + 24))) return false;
        const char *desc = str_of(x, u32(x, (size_t)x->type_off + 4u * class_type));
        size_t n = strlen(desc);
        if (n < 3 || desc[0] != 'L' || desc[n - 1] != ';') return false;
    }
    return true;
}

static bool open_apk(const char *apk_path, size_t *total, size_t *bytes, size_t *strings)
{
    tl_zip z; char err[160];
    if (!tl_zip_open(&z, apk_path, err, sizeof(err))) return false;
    dex_entry entries[TL_DEXIDX_MAX_DEX_FILES];
    size_t count = 0;
    for (size_t i = 0; i < z.count; i++) {
        uint32_t number;
        if (!dex_entry_number(z.entries[i].name, &number)) continue;
        if (count >= TL_DEXIDX_MAX_DEX_FILES || g_ndex + (int)count >= TL_DEXIDX_MAX_DEX_FILES) {
            tl_log_line("dexindex: more than %d DEX files across the app and splits", TL_DEXIDX_MAX_DEX_FILES);
            tl_zip_close(&z);
            return false;
        }
        for (size_t j = 0; j < count; j++) if (entries[j].number == number) {
            tl_log_line("dexindex: duplicate classes%u.dex entry in %s", number, apk_path);
            tl_zip_close(&z);
            return false;
        }
        entries[count++] = (dex_entry){ .number = number, .entry = &z.entries[i] };
    }
    qsort(entries, count, sizeof(entries[0]), compare_dex_entries);

    for (size_t i = 0; i < count; i++) {
        const tl_zip_entry *e = entries[i].entry;
        if (g_ndex >= TL_DEXIDX_MAX_DEX_FILES || e->usize > TL_DEXIDX_MAX_BYTES - *bytes) {
            tl_zip_close(&z);
            return false;
        }
        const uint8_t *data; size_t len; bool owned;
        if (!tl_zip_data(&z, e, TL_DEXIDX_MAX_BYTES - *bytes, &data, &len, &owned, err, sizeof(err))) { tl_zip_close(&z); return false; }
        if (!owned) {                         /* stored: it points into the APK mapping, which closing would unmap */
            uint8_t *copy = malloc(len);
            if (!copy) { tl_zip_close(&z); return false; }
            memcpy(copy, data, len);
            data = copy;
        }
        if (len < 0x70 || memcmp(data, "dex\n", 4) || data[7] != 0) {
            free((void *)data);
            tl_zip_close(&z);
            return false;
        }
        uint32_t nstr = raw_u32(data, 0x38), str_off = raw_u32(data, 0x3c);
        uint32_t ntype = raw_u32(data, 0x40), type_off = raw_u32(data, 0x44);
        uint32_t nproto = raw_u32(data, 0x48), proto_off = raw_u32(data, 0x4c);
        uint32_t nfield = raw_u32(data, 0x50), field_off = raw_u32(data, 0x54);
        uint32_t nmeth = raw_u32(data, 0x58), meth_off = raw_u32(data, 0x5c);
        uint32_t nclass = raw_u32(data, 0x60), class_off = raw_u32(data, 0x64);
        if (raw_u32(data, 0x20) != len || raw_u32(data, 0x24) != 0x70 ||
            raw_u32(data, 0x28) != 0x12345678 || len > TL_DEXIDX_MAX_BYTES - *bytes ||
            nclass > TL_DEXIDX_MAX_CLASSES - *total || nstr > TL_DEXIDX_MAX_STRINGS - *strings ||
            !table_fits(len, str_off, nstr, 4) || !table_fits(len, type_off, ntype, 4) ||
            !table_fits(len, proto_off, nproto, 12) || !table_fits(len, field_off, nfield, 8) ||
            !table_fits(len, meth_off, nmeth, 8) || !table_fits(len, class_off, nclass, 32)) {
            free((void *)data);
            tl_zip_close(&z);
            return false;
        }
        dexfile candidate = {
            .d = data, .size = len,
            .nstr = nstr, .str_off = str_off,
            .ntype = ntype, .type_off = type_off,
            .nproto = nproto, .proto_off = proto_off,
            .nfield = nfield, .field_off = field_off,
            .nmeth = nmeth, .meth_off = meth_off,
            .nclass = nclass, .class_off = class_off,
        };
        if (!validate_dex(&candidate)) {
            free((void *)data);
            tl_zip_close(&z);
            return false;
        }
        g_dex[g_ndex++] = candidate;
        *total += nclass;
        *bytes += len;
        *strings += nstr;
    }
    /* A zip kept open would pin the mapping; the dex bytes are copied or inflated, so close it. */
    tl_zip_close(&z);
    return true;
}

static void reset_unlocked(void)
{
    for (int i = 0; i < g_ndex; i++) free((void *)g_dex[i].d);
    free(g_tab);
    memset(g_dex, 0, sizeof(g_dex));
    g_ndex = 0;
    g_tab = NULL;
    g_tab_n = 0;
    g_classes = 0;
}

void tl_dexidx_reset(void)
{
    pthread_rwlock_wrlock(&g_dex_lock);
    reset_unlocked();
    pthread_rwlock_unlock(&g_dex_lock);
}

int tl_dexidx_open(const char *apk_path)
{
    pthread_rwlock_wrlock(&g_dex_lock);
    reset_unlocked();
    if (!apk_path || !apk_path[0]) { pthread_rwlock_unlock(&g_dex_lock); return -1; }
    size_t total = 0, bytes = 0, strings = 0;
    if (!open_apk(apk_path, &total, &bytes, &strings)) goto fail;
    for (int i = 0; tl_ld_queued_split(i); i++)
        if (!open_apk(tl_ld_queued_split(i), &total, &bytes, &strings)) goto fail;

    g_tab_n = 1;
    while (g_tab_n < total * 2 + 16) g_tab_n <<= 1;
    g_tab = calloc(g_tab_n, sizeof(cls_ref));
    if (!g_tab) goto fail;
    for (int di = 0; di < g_ndex; di++) {
        dexfile *x = &g_dex[di];
        for (uint32_t c = 0; c < x->nclass; c++) {
            uint32_t tid = u32(x, x->class_off + 32u * c);
            insert(di, c, type_of(x, tid));
        }
    }
    g_classes = (int)total;
    pthread_rwlock_unlock(&g_dex_lock);
    return g_classes;

fail:
    reset_unlocked();
    pthread_rwlock_unlock(&g_dex_lock);
    return -1;
}

static const cls_ref *lookup(const char *name)
{
    if (!name || !g_tab) return NULL;
    size_t i = hash_name(name, strlen(name)) & (g_tab_n - 1);
    while (g_tab[i].dex) {
        const dexfile *x = &g_dex[g_tab[i].dex - 1];
        uint32_t tid = u32(x, x->class_off + 32u * g_tab[i].def);
        if (desc_eq(type_of(x, tid), name)) return &g_tab[i];
        i = (i + 1) & (g_tab_n - 1);
    }
    return NULL;
}

bool tl_dexidx_has_class(const char *name)
{
    dex_read_lock();
    bool found = lookup(name) != NULL;
    dex_read_unlock();
    return found;
}

static const char *super_unlocked(const char *name, char *buf, size_t n)
{
    if (!buf || !n) return NULL;
    const cls_ref *r = lookup(name);
    if (!r) return NULL;
    const dexfile *x = &g_dex[r->dex - 1];
    uint32_t sup = u32(x, x->class_off + 32u * r->def + 8);
    if (sup == 0xffffffffu) return NULL;
    const char *d = type_of(x, sup);
    size_t l = strlen(d);
    if (l < 3) return NULL;
    snprintf(buf, n, "%.*s", (int)(l - 2), d + 1);
    return buf;
}

const char *tl_dexidx_super(const char *name, char *buf, size_t n)
{
    dex_read_lock();
    const char *super = super_unlocked(name, buf, n);
    dex_read_unlock();
    return super;
}

/* "(Landroid/content/Context;)V" for proto_ids[i]. */
static void proto_sig(const dexfile *x, uint32_t pi, char *out, size_t n)
{
    if (!out || !n) return;
    out[0] = 0;
    if (pi >= x->nproto || n < 4) return;
    size_t po = x->proto_off + 12u * pi;
    uint32_t ret = u32(x, po + 4), params = u32(x, po + 8);
    size_t k = 0;
    out[k++] = '(';
    if (params) {
        uint32_t cnt = u32(x, params);
        for (uint32_t i = 0; i < cnt; i++) {
            const char *t = type_of(x, u16(x, params + 4 + 2u * i));
            size_t l = strlen(t);
            if (k >= n || l > n - k - 3) { out[0] = 0; return; }
            memcpy(out + k, t, l); k += l;
        }
    }
    out[k++] = ')';
    const char *rt = type_of(x, ret);
    size_t l = strlen(rt);
    if (l >= n - k) { out[0] = 0; return; }
    memcpy(out + k, rt, l);
    out[k + l] = 0;
}

static bool scan_members(const char *cls, bool want_method, const char *name, const char *sig, bool *is_static, char *sig_out, size_t sig_n)
{
    const cls_ref *r = lookup(cls);
    if (!r) return false;
    const dexfile *x = &g_dex[r->dex - 1];
    uint32_t cdata = u32(x, x->class_off + 32u * r->def + 24);
    if (!cdata) return false;
    size_t o = cdata;
    uint32_t nsf = uleb(x, &o), nif = uleb(x, &o), ndm = uleb(x, &o), nvm = uleb(x, &o);
    uint32_t counts[4] = { nsf, nif, ndm, nvm };
    for (int group = 0; group < 4; group++) {
        bool method_group = group >= 2;
        uint32_t idx = 0;
        for (uint32_t i = 0; i < counts[group]; i++) {
            idx += uleb(x, &o);
            uint32_t flags = uleb(x, &o);
            if (method_group) uleb(x, &o);              /* code_off */
            if (method_group != want_method) continue;
            if (method_group) {
                size_t mo = x->meth_off + 8u * idx;
                uint32_t nameidx = u32(x, mo + 4); uint16_t protoidx = u16(x, mo + 2);
                if (strcmp(str_of(x, nameidx), name)) continue;
                if (sig && *sig) { char ps[512]; proto_sig(x, protoidx, ps, sizeof(ps)); if (strcmp(ps, sig)) continue; }
                if (sig_out) proto_sig(x, protoidx, sig_out, sig_n);
            } else {
                size_t fo = x->field_off + 8u * idx;
                uint16_t typeidx = u16(x, fo + 2); uint32_t nameidx = u32(x, fo + 4);
                if (strcmp(str_of(x, nameidx), name)) continue;
                if (sig && *sig && strcmp(type_of(x, typeidx), sig)) continue;
                if (sig_out) snprintf(sig_out, sig_n, "%s", type_of(x, typeidx));
            }
            if (is_static) *is_static = (flags & 8) != 0;
            return true;
        }
    }
    return false;
}

/* Split "(A B C)R" into parameter descriptors; returns the count and points `ret` at R. */
static int split_sig(const char *sig, const char **params, int *plen, int max, const char **ret)
{
    int n = 0;
    const char *p = sig;
    if (*p != '(') return -1;
    p++;
    while (*p && *p != ')' && n < max) {
        const char *start = p;
        while (*p == '[') p++;
        if (*p == 'L') { while (*p && *p != ';') p++; if (*p) p++; } else if (*p) p++;
        params[n] = start; plen[n] = (int)(p - start); n++;
    }
    if (*p != ')') return -1;
    *ret = p + 1;
    return n;
}
static bool is_object_desc(const char *d) { return d[0] == 'L' || d[0] == '['; }

/*
 * A method by name and parameters, tolerant the way Unity's reflection helper is: an argument given as
 * "Ljava/lang/Object;" (null, or an AndroidJavaObject) fits any object parameter, and any object return type
 * fits any other. Writes the declared signature to `out`.
 */
static bool find_method_lenient_unlocked(const char *cls, const char *name, const char *want, char *out, size_t n, bool *is_static)
{
    const cls_ref *r = lookup(cls);
    if (!r) return false;
    const dexfile *x = &g_dex[r->dex - 1];
    uint32_t cdata = u32(x, x->class_off + 32u * r->def + 24);
    if (!cdata) return false;
    const char *wp[40]; int wl[40]; const char *wret;
    int wn = split_sig(want, wp, wl, 40, &wret);
    if (wn < 0) return false;
    size_t o = cdata;
    uint32_t nsf = uleb(x, &o), nif = uleb(x, &o), ndm = uleb(x, &o), nvm = uleb(x, &o);
    uint32_t counts[4] = { nsf, nif, ndm, nvm };
    int best = -1;
    for (int group = 0; group < 4; group++) {
        uint32_t idx = 0;
        for (uint32_t i = 0; i < counts[group]; i++) {
            idx += uleb(x, &o);
            uint32_t flags = uleb(x, &o);
            if (group >= 2) uleb(x, &o);
            if (group < 2) continue;
            size_t mo = x->meth_off + 8u * idx;
            if (strcmp(str_of(x, u32(x, mo + 4)), name)) continue;
            char ps[512]; proto_sig(x, u16(x, mo + 2), ps, sizeof(ps));
            const char *dp[40]; int dl[40]; const char *dret;
            int dn = split_sig(ps, dp, dl, 40, &dret);
            if (dn != wn) continue;
            /* An object argument fits any object parameter (a subclass, or Object for a null); the most exact fit wins. */
            bool ok = true; int exact = 0;
            for (int k = 0; k < dn && ok; k++) {
                bool same = dl[k] == wl[k] && !strncmp(dp[k], wp[k], (size_t)dl[k]);
                if (same) exact++;
                else ok = is_object_desc(dp[k]) && is_object_desc(wp[k]);
            }
            if (!ok) continue;
            if (!(is_object_desc(dret) && is_object_desc(wret)) && strcmp(dret, wret)) continue;
            if (exact > best) {
                best = exact;
                snprintf(out, n, "%s", ps);
                if (is_static) *is_static = (flags & 8) != 0;
            }
        }
    }
    return best >= 0;
}

bool tl_dexidx_find_method_lenient(const char *cls, const char *name, const char *want, char *out, size_t n, bool *is_static)
{
    dex_read_lock();
    bool found = find_method_lenient_unlocked(cls, name, want, out, n, is_static);
    dex_read_unlock();
    return found;
}

static void each_member_unlocked(const char *cls, bool methods, void (*fn)(const char *name, const char *sig, uint32_t flags, void *ctx), void *ctx)
{
    const cls_ref *r = lookup(cls);
    if (!r) return;
    const dexfile *x = &g_dex[r->dex - 1];
    uint32_t cdata = u32(x, x->class_off + 32u * r->def + 24);
    if (!cdata) return;
    size_t o = cdata;
    uint32_t nsf = uleb(x, &o), nif = uleb(x, &o), ndm = uleb(x, &o), nvm = uleb(x, &o);
    uint32_t counts[4] = { nsf, nif, ndm, nvm };
    for (int group = 0; group < 4; group++) {
        bool method_group = group >= 2;
        uint32_t idx = 0;
        for (uint32_t i = 0; i < counts[group]; i++) {
            idx += uleb(x, &o);
            uint32_t flags = uleb(x, &o);
            if (method_group) uleb(x, &o);
            if (method_group != methods) continue;
            if (method_group) {
                size_t mo = x->meth_off + 8u * idx;
                char ps[512]; proto_sig(x, u16(x, mo + 2), ps, sizeof(ps));
                fn(str_of(x, u32(x, mo + 4)), ps, flags, ctx);
            } else {
                size_t fo = x->field_off + 8u * idx;
                fn(str_of(x, u32(x, fo + 4)), type_of(x, u16(x, fo + 2)), flags, ctx);
            }
        }
    }
}

void tl_dexidx_each_member(const char *cls, bool methods, void (*fn)(const char *name, const char *sig, uint32_t flags, void *ctx), void *ctx)
{
    if (!fn) return;
    dex_read_lock();
    each_member_unlocked(cls, methods, fn, ctx);
    dex_read_unlock();
}

static uint32_t class_flags_unlocked(const char *cls)
{
    const cls_ref *r = lookup(cls);
    if (!r) return 0;
    const dexfile *x = &g_dex[r->dex - 1];
    return u32(x, x->class_off + 32u * r->def + 4);
}

uint32_t tl_dexidx_class_flags(const char *cls)
{
    dex_read_lock();
    uint32_t flags = class_flags_unlocked(cls);
    dex_read_unlock();
    return flags;
}

bool tl_dexidx_declares_method(const char *cls, const char *name, const char *sig, bool *st)
{
    dex_read_lock();
    bool found = scan_members(cls, true, name, sig, st, NULL, 0);
    dex_read_unlock();
    return found;
}

bool tl_dexidx_declares_field(const char *cls, const char *name, const char *sig, bool *st)
{
    dex_read_lock();
    bool found = scan_members(cls, false, name, sig, st, NULL, 0);
    dex_read_unlock();
    return found;
}

bool tl_dexidx_field_sig(const char *cls, const char *name, char *out, size_t n)
{
    dex_read_lock();
    bool found = scan_members(cls, false, name, "", NULL, out, n);
    dex_read_unlock();
    return found;
}

bool tl_dexidx_method_named(const char *cls, const char *name)
{
    dex_read_lock();
    bool found = scan_members(cls, true, name, "", NULL, NULL, 0);
    dex_read_unlock();
    return found;
}

bool tl_dexidx_method_sig(const char *cls, const char *name, char *out, size_t n, bool *is_static)
{
    dex_read_lock();
    bool found = scan_members(cls, true, name, "", is_static, out, n);
    dex_read_unlock();
    return found;
}

static void each_string_unlocked(bool (*fn)(const char *s, void *ctx), void *ctx)
{
    for (int di = 0; di < g_ndex; di++)
        for (uint32_t i = 0; i < g_dex[di].nstr; i++)
            if (!fn(str_of(&g_dex[di], i), ctx)) return;
}

void tl_dexidx_each_string(bool (*fn)(const char *s, void *ctx), void *ctx)
{
    if (!fn) return;
    dex_read_lock();
    each_string_unlocked(fn, ctx);
    dex_read_unlock();
}
