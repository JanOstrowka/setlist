from io import BytesIO

from PIL import Image

from app.core.resolver import (
    to_square_jpeg,
    detected_line,
    jpeg_to_data_uri,
    data_uri_to_bytes,
    augment_error,
)


def test_to_square_jpeg_makes_square_jpeg():
    img = Image.new("RGB", (640, 360), (10, 20, 30))
    buf = BytesIO()
    img.save(buf, format="PNG")
    out = to_square_jpeg(buf.getvalue())
    result = Image.open(BytesIO(out))
    assert result.width == result.height
    assert result.format == "JPEG"


def test_to_square_jpeg_caps_max_size():
    img = Image.new("RGB", (2000, 2000), (0, 0, 0))
    buf = BytesIO()
    img.save(buf, format="PNG")
    out = to_square_jpeg(buf.getvalue(), max_size=1400)
    result = Image.open(BytesIO(out))
    assert result.width == 1400 and result.height == 1400


def test_detected_line_alac_includes_size_note():
    line = detected_line("251 · opus · ~160 kbps", "alac", "/Music/YT")
    assert "ALAC lossless" in line
    assert "~5-10x" in line
    assert "/Music/YT" in line


def test_detected_line_aac_has_no_size_note():
    line = detected_line("251 · opus · ~160 kbps", "aac256", "/Music/YT")
    assert "AAC 256 kbps" in line
    assert "~5-10x" not in line


def test_data_uri_roundtrip():
    uri = jpeg_to_data_uri(b"hello-bytes")
    assert uri.startswith("data:image/jpeg;base64,")
    assert data_uri_to_bytes(uri) == b"hello-bytes"
    assert data_uri_to_bytes("aGVsbG8=") == b"hello"  # bare base64, no prefix


def test_augment_error_adds_pot_hint_for_bot_check():
    msg = augment_error(RuntimeError("Sign in to confirm you're not a bot"))
    assert "POT_PROVIDER_URL" in msg


def test_augment_error_passthrough_for_plain_error():
    msg = augment_error(ValueError("unsupported url"))
    assert msg == "unsupported url"
    assert "POT_PROVIDER_URL" not in msg
