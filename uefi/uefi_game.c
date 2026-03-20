#include <efi.h>
#include <efilib.h>

/* ============================================================================
 * CONSTANTS
 * ========================================================================== */

#define BLOCK_SIZE      18

#define GLYPH_ROWS      5
#define GLYPH_COLS      4

#define LETTER_STRIDE   (GLYPH_COLS + 1)

#define NAME2_ROW_OFFSET 7

#define MAX_NAME_COL    20
#define MAX_NAME_ROW    7
#define MIN_NAME_ROW    1

#define COLOR_BG_R 0
#define COLOR_BG_G 0
#define COLOR_BG_B 64

#define COLOR_GLYPH_R 0
#define COLOR_GLYPH_G 255
#define COLOR_GLYPH_B 64

#define COLOR_STATUS_R 255
#define COLOR_STATUS_G 255
#define COLOR_STATUS_B 0

/* ============================================================================
 * TYPES
 * ========================================================================== */

typedef enum {
    ROT_NORMAL    = 0,  /**< No rotation */
    ROT_RIGHT_90  = 1,  /**< 90° clockwise */
    ROT_180       = 2,  /**< 180° */
    ROT_LEFT_90   = 3   /**< 90° counter-clockwise */
} RotationState;

typedef struct {
    INT32         name_col; 
    INT32         name_row;
    RotationState rotation;
    BOOLEAN       vertical_flip;
    UINT16        rng_seed;
} GameState;

/* ============================================================================
 * GLYPH BITMAPS
 * ========================================================================== */

static const UINT8 GLYPH_A[20] = { 0,1,1,0, 1,0,0,1, 1,1,1,1, 1,0,0,1, 1,0,0,1 };
static const UINT8 GLYPH_N[20] = { 1,0,0,1, 1,1,0,1, 1,0,1,1, 1,0,0,1, 1,0,0,1 };
static const UINT8 GLYPH_D[20] = { 1,1,0,0, 1,0,1,0, 1,0,0,1, 1,0,1,0, 1,1,0,0 };
static const UINT8 GLYPH_R[20] = { 1,1,1,0, 1,0,0,1, 1,1,1,0, 1,0,1,0, 1,0,0,1 };
static const UINT8 GLYPH_E[20] = { 1,1,1,1, 1,0,0,0, 1,1,1,0, 1,0,0,0, 1,1,1,1 };
static const UINT8 GLYPH_S[20] = { 0,1,1,1, 1,0,0,0, 0,1,1,0, 0,0,0,1, 1,1,1,0 };
static const UINT8 GLYPH_M[20] = { 1,0,0,1, 1,1,1,1, 1,0,0,1, 1,0,0,1, 1,0,0,1 };
static const UINT8 GLYPH_C[20] = { 0,1,1,1, 1,0,0,0, 1,0,0,0, 1,0,0,0, 0,1,1,1 };
static const UINT8 GLYPH_O[20] = { 0,1,1,0, 1,0,0,1, 1,0,0,1, 1,0,0,1, 0,1,1,0 };

/** ANDRES: 6 glyphs in order. */
static const UINT8 *NAME1_GLYPHS[] = {
    GLYPH_A, GLYPH_N, GLYPH_D, GLYPH_R, GLYPH_E, GLYPH_S
};
#define NAME1_LEN 6

/** MARCO: 5 glyphs in order. */
static const UINT8 *NAME2_GLYPHS[] = {
    GLYPH_M, GLYPH_A, GLYPH_R, GLYPH_C, GLYPH_O
};
#define NAME2_LEN 5

/* ============================================================================
 * PRNG
 * ========================================================================== */
static UINT8 rand_byte(GameState *state)
{
    state->rng_seed = (UINT16)(state->rng_seed * 6364u + 1013u);
    return (UINT8)(state->rng_seed >> 8);
}

static void seed_rng(GameState *state,
                     EFI_RUNTIME_SERVICES *RuntimeSvcs)
{
    EFI_TIME now;
    EFI_TIME_CAPABILITIES caps;

    EFI_STATUS s = RuntimeSvcs->GetTime(&now, &caps);
    if (!EFI_ERROR(s))
    {
        UINT8 sec_part = (UINT8)(now.Second);
        UINT8 ns_part  = (UINT8)(now.Nanosecond >> 23);
        state->rng_seed = (UINT16)((sec_part << 8) | ns_part);
    }
    else
    {
        state->rng_seed = 0xACE1u;
    }
}

/* ============================================================================
 * RENDERING
 * ========================================================================== */

static void put_pixel(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop,
                      UINTN x, UINTN y,
                      UINT8 r, UINT8 g, UINT8 b)
{
    UINT32 *fb = (UINT32 *)gop->Mode->FrameBufferBase;
    UINTN stride = gop->Mode->Info->PixelsPerScanLine;

    if (x >= gop->Mode->Info->HorizontalResolution) return;
    if (y >= gop->Mode->Info->VerticalResolution)   return;

    /* Pack color into the correct byte order based on the pixel format.
     * PixelBlueGreenRedReserved (BGRX): value = (r<<16)|(g<<8)|b
     * PixelRedGreenBlueReserved (RGBX): value = (b<<16)|(g<<8)|r
     * QEMU uses RGBX by default, real hardware typically uses BGRX.
     * We check the pixel format at runtime to support both. */
    UINT32 pixel;
    if (gop->Mode->Info->PixelFormat == PixelRedGreenBlueReserved8BitPerColor)
        pixel = ((UINT32)b << 16) | ((UINT32)g << 8) | r;
    else
        pixel = ((UINT32)r << 16) | ((UINT32)g << 8) | b;

    fb[y * stride + x] = pixel;
}

static void fill_block(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop,
                       INT32 log_x, INT32 log_y,
                       UINT8 r, UINT8 g, UINT8 b)
{
    for (INT32 dy = 0; dy < BLOCK_SIZE; dy++)
        for (INT32 dx = 0; dx < BLOCK_SIZE; dx++)
            put_pixel(gop,
                      (UINTN)(log_x * BLOCK_SIZE + dx),
                      (UINTN)(log_y * BLOCK_SIZE + dy),
                      r, g, b);
}

static void clear_screen(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop)
{
    EFI_GRAPHICS_OUTPUT_BLT_PIXEL bg = {
        .Blue     = COLOR_BG_B,
        .Green    = COLOR_BG_G,
        .Red      = COLOR_BG_R,
        .Reserved = 0
    };

    gop->Blt(gop, &bg, EfiBltVideoFill,
             0, 0,
             0, 0,
             gop->Mode->Info->HorizontalResolution,
             gop->Mode->Info->VerticalResolution,
             0);
}

static void transform(const GameState *state,
                      INT32 src_r, INT32 src_c,
                      INT32 row_offset, INT32 col_offset,
                      INT32 *out_r, INT32 *out_c)
{
    INT32 r, c;

    switch (state->rotation)
    {
        case ROT_NORMAL:
            r = src_r;
            c = src_c;
            break;

        case ROT_RIGHT_90:
            r = src_c;
            c = 4 - src_r;
            break;

        case ROT_180:
            r = 4 - src_r;
            c = 3 - src_c;
            break;

        case ROT_LEFT_90:
            r = 3 - src_c;
            c = src_r;
            break;

        default:
            r = src_r;
            c = src_c;
            break;
    }

    if (state->vertical_flip)
        r = 4 - r;

    *out_r = state->name_row + row_offset + r;
    *out_c = state->name_col + col_offset + c;
}

static void draw_glyph(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop,
                       const GameState *state,
                       const UINT8 *glyph,
                       INT32 row_offset,
                       INT32 col_offset)
{
    for (INT32 sr = 0; sr < GLYPH_ROWS; sr++)
    {
        for (INT32 sc = 0; sc < GLYPH_COLS; sc++)
        {
            if (!glyph[sr * GLYPH_COLS + sc])
                continue;  /* Empty cell — skip */

            INT32 out_r, out_c;
            transform(state, sr, sc, row_offset, col_offset, &out_r, &out_c);

            fill_block(gop, out_c, out_r, COLOR_GLYPH_R, COLOR_GLYPH_G, COLOR_GLYPH_B);
        }
    }
}

static void print_status(SIMPLE_TEXT_OUTPUT_INTERFACE *ConOut,
                         UINTN row, CHAR16 *str)
{
    ConOut->SetCursorPosition(ConOut, 0, row);
    ConOut->OutputString(ConOut, str);
}

static void render(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop,
                   SIMPLE_TEXT_OUTPUT_INTERFACE *ConOut,
                   const GameState *state)
{
    clear_screen(gop);

    /* Draw ANDRES — row_offset = 0 */
    for (INT32 i = 0; i < NAME1_LEN; i++)
        draw_glyph(gop, state, NAME1_GLYPHS[i], 0, i * LETTER_STRIDE);

    /* Draw MARCO — row_offset = NAME2_ROW_OFFSET = 7 */
    for (INT32 i = 0; i < NAME2_LEN; i++)
        draw_glyph(gop, state, NAME2_GLYPHS[i],
                   NAME2_ROW_OFFSET, i * LETTER_STRIDE);

    print_status(ConOut, 23,
                 L" [<][>]=Rotate  [^][v]=Flip  [R]=Restart  [ESC]=Quit ");
}

/* ============================================================================
 * GAME LOGIC
 * ========================================================================== */

static void init_game_state(GameState *state)
{
    state->name_col = rand_byte(state) % (MAX_NAME_COL + 1);
    state->name_row = MIN_NAME_ROW + (rand_byte(state) % MAX_NAME_ROW);
    state->rotation      = ROT_NORMAL;
    state->vertical_flip = FALSE;
}

static void read_key(EFI_BOOT_SERVICES *BS,
                     SIMPLE_INPUT_INTERFACE *ConIn,
                     EFI_INPUT_KEY *key)
{
    UINTN index;
    BS->WaitForEvent(1, &ConIn->WaitForKey, &index);
    ConIn->ReadKeyStroke(ConIn, key);
}

static BOOLEAN show_confirm_screen(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop,
                                   SIMPLE_TEXT_OUTPUT_INTERFACE *ConOut,
                                   EFI_BOOT_SERVICES *BS,
                                   SIMPLE_INPUT_INTERFACE *ConIn)
{
    clear_screen(gop);

    ConOut->SetCursorPosition(ConOut, 24, 8);
    ConOut->OutputString(ConOut, L"=== MY NAME: ANDRES & MARCO ===");

    ConOut->SetCursorPosition(ConOut, 24, 12);
    ConOut->OutputString(ConOut, L"Press Y to play or ESC to exit");

    ConOut->SetCursorPosition(ConOut, 19, 14);
    ConOut->OutputString(ConOut, L"[<][>]=Rotate  [^][v]=Flip  [R]=Restart  [ESC]=Quit");

    for (;;)
    {
        EFI_INPUT_KEY key;
        read_key(BS, ConIn, &key);

        if (key.UnicodeChar == L'y' || key.UnicodeChar == L'Y')
            return TRUE;
        if (key.ScanCode == SCAN_ESC || key.UnicodeChar == 0x1B)
            return FALSE;
    }
}

static void game_loop(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop,
                      SIMPLE_TEXT_OUTPUT_INTERFACE *ConOut,
                      EFI_BOOT_SERVICES *BS,
                      SIMPLE_INPUT_INTERFACE *ConIn,
                      GameState *state)
{
    for (;;)
    {
        init_game_state(state);
        render(gop, ConOut, state);

        for (;;)
        {
            EFI_INPUT_KEY key;
            read_key(BS, ConIn, &key);

            BOOLEAN changed = FALSE;

            if (key.ScanCode == SCAN_ESC || key.UnicodeChar == 0x1B)
                return;

            if (key.UnicodeChar == L'r' || key.UnicodeChar == L'R')
                break;

            if (key.ScanCode == SCAN_LEFT)
            {
                state->rotation = (RotationState)((state->rotation + 3) % 4);
                changed = TRUE;
            }
            else if (key.ScanCode == SCAN_RIGHT)
            {
                state->rotation = (RotationState)((state->rotation + 1) % 4);
                changed = TRUE;
            }
            else if (key.ScanCode == SCAN_UP || key.ScanCode == SCAN_DOWN)
            {
                state->vertical_flip = !state->vertical_flip;
                changed = TRUE;
            }

            if (changed)
                render(gop, ConOut, state);
        }
    }
}

/* ============================================================================
 * EFI ENTRY POINT
 * ========================================================================== */

EFI_STATUS
EFIAPI
efi_main(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable) {

    InitializeLib(ImageHandle, SystemTable);

    SystemTable->BootServices->SetWatchdogTimer(0, 0, 0, NULL);

    EFI_GUID gop_guid = EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID;
    EFI_GRAPHICS_OUTPUT_PROTOCOL *gop = NULL;

    EFI_STATUS status = SystemTable->BootServices->LocateProtocol(
        &gop_guid, NULL, (VOID **)&gop);

    if (EFI_ERROR(status))
    {
        SystemTable->ConOut->ClearScreen(SystemTable->ConOut);
        Print(L"Error: Graphics Output Protocol not available (%r)\n", status);
        Print(L"This game requires a GOP-capable display.\n");
        Print(L"Press any key to exit.\n");

        UINTN idx;
        SystemTable->BootServices->WaitForEvent(
            1, &SystemTable->ConIn->WaitForKey, &idx);
        EFI_INPUT_KEY k;
        SystemTable->ConIn->ReadKeyStroke(SystemTable->ConIn, &k);
        return status;
    }

    GameState state = { 0 };
    seed_rng(&state, SystemTable->RuntimeServices);

    BOOLEAN start = show_confirm_screen(
        gop,
        SystemTable->ConOut,
        SystemTable->BootServices,
        SystemTable->ConIn);

    if (start)
    {
        game_loop(
            gop,
            SystemTable->ConOut,
            SystemTable->BootServices,
            SystemTable->ConIn,
            &state);
    }

    SystemTable->ConOut->ClearScreen(SystemTable->ConOut);
    SystemTable->ConOut->SetCursorPosition(SystemTable->ConOut, 0, 0);
    Print(L"Exiting game. Returning to firmware...\n");

    return EFI_SUCCESS;
}