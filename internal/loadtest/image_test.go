package loadtest

import (
	"bytes"
	"image/jpeg"
	"testing"
)

func TestAvatarJPEGDeterministic(t *testing.T) {
	a, err := AvatarJPEG("user-1", 128)
	if err != nil {
		t.Fatalf("AvatarJPEG: %v", err)
	}
	b, err := AvatarJPEG("user-1", 128)
	if err != nil {
		t.Fatalf("AvatarJPEG: %v", err)
	}
	if !bytes.Equal(a, b) {
		t.Error("same seed produced different bytes")
	}
	c, err := AvatarJPEG("user-2", 128)
	if err != nil {
		t.Fatalf("AvatarJPEG: %v", err)
	}
	if bytes.Equal(a, c) {
		t.Error("different seeds produced identical bytes")
	}
}

func TestAvatarJPEGDecodesWithSize(t *testing.T) {
	data, err := AvatarJPEG("seed", 96)
	if err != nil {
		t.Fatalf("AvatarJPEG: %v", err)
	}
	if len(data) < 100 {
		t.Fatalf("suspiciously small jpeg: %d bytes", len(data))
	}
	img, err := jpeg.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("jpeg.Decode: %v", err)
	}
	b := img.Bounds()
	if b.Dx() != 96 || b.Dy() != 96 {
		t.Errorf("avatar dims = %dx%d, want 96x96", b.Dx(), b.Dy())
	}
}

func TestBannerJPEGDecodesWithSize(t *testing.T) {
	data, err := BannerJPEG("group-1", 800, 300)
	if err != nil {
		t.Fatalf("BannerJPEG: %v", err)
	}
	img, err := jpeg.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("jpeg.Decode: %v", err)
	}
	b := img.Bounds()
	if b.Dx() != 800 || b.Dy() != 300 {
		t.Errorf("banner dims = %dx%d, want 800x300", b.Dx(), b.Dy())
	}
}

func TestImageRejectsBadSize(t *testing.T) {
	if _, err := AvatarJPEG("x", 0); err == nil {
		t.Error("want error for size 0")
	}
	if _, err := BannerJPEG("x", -1, 10); err == nil {
		t.Error("want error for negative width")
	}
}
