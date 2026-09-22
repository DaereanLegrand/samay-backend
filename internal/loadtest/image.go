package loadtest

import (
	"bytes"
	"fmt"
	"hash/fnv"
	"image"
	"image/color"
	"image/draw"
	"image/jpeg"
	"math/rand"
)

// hashSeed maps a seed string to a stable 64-bit value.
func hashSeed(seed string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(seed))
	return h.Sum64()
}

// colorFromHash derives a vivid, deterministic color from a hash and salt.
func colorFromHash(h, salt uint64) color.RGBA {
	x := h ^ (salt * 0x9E3779B97F4A7C15)
	return color.RGBA{
		R: uint8(48 + (x>>0)%176),
		G: uint8(48 + (x>>8)%176),
		B: uint8(48 + (x>>16)%176),
		A: 255,
	}
}

func encodeJPEG(img image.Image) ([]byte, error) {
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 85}); err != nil {
		return nil, fmt.Errorf("encode jpeg: %w", err)
	}
	return buf.Bytes(), nil
}

// AvatarJPEG renders a deterministic square identicon for seed.
func AvatarJPEG(seed string, size int) ([]byte, error) {
	if size <= 0 {
		return nil, fmt.Errorf("avatar size must be > 0, got %d", size)
	}
	h := hashSeed(seed)
	rng := rand.New(rand.NewSource(int64(h)))
	bg := colorFromHash(h, 1)
	fg := colorFromHash(h, 2)

	img := image.NewRGBA(image.Rect(0, 0, size, size))
	draw.Draw(img, img.Bounds(), &image.Uniform{C: bg}, image.Point{}, draw.Src)

	const cells = 5
	cell := size / cells
	if cell < 1 {
		cell = 1
	}
	for y := 0; y < cells; y++ {
		for x := 0; x < 3; x++ {
			if rng.Intn(2) == 0 {
				continue
			}
			for _, cx := range []int{x, cells - 1 - x} {
				rect := image.Rect(cx*cell, y*cell, (cx+1)*cell, (y+1)*cell)
				draw.Draw(img, rect, &image.Uniform{C: fg}, image.Point{}, draw.Src)
			}
		}
	}
	return encodeJPEG(img)
}

// BannerJPEG renders a deterministic gradient banner with subtle stripes.
func BannerJPEG(seed string, w, h int) ([]byte, error) {
	if w <= 0 || h <= 0 {
		return nil, fmt.Errorf("banner dimensions must be > 0, got %dx%d", w, h)
	}
	hh := hashSeed(seed)
	top := colorFromHash(hh, 3)
	bottom := colorFromHash(hh, 4)
	stripe := colorFromHash(hh, 5)
	rng := rand.New(rand.NewSource(int64(hh)))
	stripeOffset := rng.Intn(64)
	stripeWidth := 8 + rng.Intn(40)

	img := image.NewRGBA(image.Rect(0, 0, w, h))
	denom := h - 1
	if denom < 1 {
		denom = 1
	}
	for y := 0; y < h; y++ {
		t := float64(y) / float64(denom)
		row := lerpColor(top, bottom, t)
		for x := 0; x < w; x++ {
			c := row
			if ((x+y+stripeOffset)/stripeWidth)%3 == 0 {
				c = blend(row, stripe, 0.18)
			}
			img.SetRGBA(x, y, c)
		}
	}
	return encodeJPEG(img)
}

func lerpColor(a, b color.RGBA, t float64) color.RGBA {
	lerp := func(x, y uint8) uint8 {
		return uint8(float64(x) + (float64(y)-float64(x))*t)
	}
	return color.RGBA{R: lerp(a.R, b.R), G: lerp(a.G, b.G), B: lerp(a.B, b.B), A: 255}
}

func blend(a, b color.RGBA, t float64) color.RGBA {
	lerp := func(x, y uint8) uint8 {
		return uint8(float64(x)*(1-t) + float64(y)*t)
	}
	return color.RGBA{R: lerp(a.R, b.R), G: lerp(a.G, b.G), B: lerp(a.B, b.B), A: 255}
}
