// Cross-check harness: runs MAME's own kaneko_rle_sprites_device::{rle_decode, draw_sprites, blit_*_z} -- the text of
// ref/mame/src/mame/kaneko/kaneko_rlespr.cpp from "int kaneko_rle_sprites_device::rle_decode" to the end, included UNMODIFIED
// (tools/xcheck_rlespr.py cuts it into mame_rlespr_body.inc) -- on case files made by tools/xcheck_rlespr.py, and prints a CRC32 of the
// complete 512 x 512 sprite bitmap after every frame (optionally the bitmap itself).
//
// Only the types the file needs from MAME's emu.h are stubbed here.
//
//   harness <cases.bin> <crc-out.txt> [dumpcase dumpframe dump.bin]
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef int16_t s16;
typedef int32_t s32;
typedef uint32_t offs_t;

template <typename T, typename U> constexpr T BIT(T x, U n) noexcept { return (x >> n) & T(1); }

struct rectangle
{
	s32 min_x = 0, max_x = 0, min_y = 0, max_y = 0;
	rectangle &operator&=(const rectangle &o)
	{
		if (o.min_x > min_x) min_x = o.min_x;
		if (o.max_x < max_x) max_x = o.max_x;
		if (o.min_y > min_y) min_y = o.min_y;
		if (o.max_y < max_y) max_y = o.max_y;
		return *this;
	}
};

class bitmap_ind16
{
public:
	void allocate(int w, int h) { m_w = w; m_h = h; m_d.assign(size_t(w) * h, 0); }
	u16 &pix(int y, int x) { return m_d[size_t(y) * m_w + x]; }
	u16 &pix(int y) { return m_d[size_t(y) * m_w]; }
	void fill(u16 v, const rectangle &r)
	{
		for (int y = r.min_y; y <= r.max_y; y++)
			for (int x = r.min_x; x <= r.max_x; x++)
				pix(y, x) = v;
	}
	rectangle cliprect() const { rectangle r; r.max_x = m_w - 1; r.max_y = m_h - 1; return r; }
	const u16 *data() const { return m_d.data(); }
private:
	int m_w = 0, m_h = 0;
	std::vector<u16> m_d;
};

struct screen_stub
{
	rectangle visible_area() const { rectangle r; r.max_x = 319; r.max_y = 239; return r; }
};

class kaneko_rle_sprites_device
{
public:
	static constexpr unsigned DECODE_BUFFER_SIZE = 0x2000;
	static constexpr unsigned DECODE_BUFFER_MASK = DECODE_BUFFER_SIZE - 1;
	static constexpr size_t ROM_ADDRESS_MASK = (1 << 27) - 1;

	kaneko_rle_sprites_device(const u8 *rom, size_t rom_size) : m_rom(rom), m_rom_size(rom_size)
	{
		m_decodebuffer = std::make_unique<u8[]>(DECODE_BUFFER_SIZE);
		memset(m_decodebuffer.get(), 0, DECODE_BUFFER_SIZE);
		for (int i = 0; i < 2; i++)
			m_sprite_bitmap[i].allocate(512, 512);
	}

	u8 read_byte(offs_t a) const { return a < m_rom_size ? m_rom[a] : 0; }
	screen_stub &screen() { return m_screen; }
	bitmap_ind16 &bitmap() { return m_sprite_bitmap[m_buffer]; }

	void set_sprite_kludge(int x, int y);
	void draw_sprites(const rectangle &cliprect, u32 *spriteram_source, size_t spriteram_size, u32 *sprite_regs);

private:
	int m_sprite_kludge_x = 0, m_sprite_kludge_y = 0;
	std::unique_ptr<u8[]> m_decodebuffer;
	bitmap_ind16 m_sprite_bitmap[2];
	u8 m_buffer = 0;
	const u8 *m_rom;
	size_t m_rom_size;
	screen_stub m_screen;

	int rle_decode(int romoffset, int size);
};

// ---- MAME's code, verbatim ------------------------------------------------------------------------------------------
#include "mame_rlespr_body.inc"
// ---------------------------------------------------------------------------------------------------------------------

static u32 crc_table[256];
static void crc_init()
{
	for (u32 i = 0; i < 256; i++)
	{
		u32 c = i;
		for (int k = 0; k < 8; k++) c = (c & 1) ? 0xedb88320u ^ (c >> 1) : c >> 1;
		crc_table[i] = c;
	}
}
static u32 crc32(const u8 *p, size_t n)
{
	u32 c = 0xffffffffu;
	for (size_t i = 0; i < n; i++) c = crc_table[(c ^ p[i]) & 0xff] ^ (c >> 8);
	return c ^ 0xffffffffu;
}

template <typename T> static bool rd(FILE *f, T &v) { return fread(&v, sizeof v, 1, f) == 1; }

int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: harness cases.bin crc.txt [case frame dump.bin]\n"); return 2; }
	crc_init();
	FILE *f = fopen(argv[1], "rb");
	if (!f) { perror(argv[1]); return 1; }
	char magic[4]; u32 ncases, rom_size;
	if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "RLEX", 4) || !rd(f, ncases) || !rd(f, rom_size)) { fprintf(stderr, "bad case file\n"); return 1; }
	std::vector<u8> rom(rom_size);
	if (fread(rom.data(), 1, rom_size, f) != rom_size) { fprintf(stderr, "short rom\n"); return 1; }
	FILE *out = fopen(argv[2], "w");
	int dcase = -1, dframe = -1;
	FILE *dump = nullptr;
	if (argc >= 6) { dcase = atoi(argv[3]); dframe = atoi(argv[4]); dump = fopen(argv[5], "wb"); }

	for (u32 c = 0; c < ncases; c++)
	{
		s32 kx, ky; u32 nframes;
		rd(f, kx); rd(f, ky); rd(f, nframes);
		kaneko_rle_sprites_device dev(rom.data(), rom.size());
		dev.set_sprite_kludge(kx, ky);
		for (u32 fr = 0; fr < nframes; fr++)
		{
			u32 nwords; u32 regs[16];
			rd(f, nwords);
			if (fread(regs, 4, 16, f) != 16) return 1;
			std::vector<u32> ram(nwords);
			if (nwords && fread(ram.data(), 4, nwords, f) != nwords) return 1;
			rectangle clip; clip.max_x = 319; clip.max_y = 239;
			dev.draw_sprites(clip, ram.data(), size_t(nwords) * 4, regs);
			const u16 *bm = dev.bitmap().data();
			fprintf(out, "%u %u %08x\n", c, fr, crc32(reinterpret_cast<const u8 *>(bm), 512 * 512 * 2));
			if (dump && int(c) == dcase && int(fr) == dframe)
			{
				fwrite(bm, 2, 512 * 512, dump);
			}
		}
	}
	fclose(out);
	if (dump) fclose(dump);
	return 0;
}
