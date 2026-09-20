import sys

from app.main import yt_dlp_update_command


def test_source_checkout_upgrades_in_place():
    cmd = yt_dlp_update_command(None)

    assert cmd[:3] == [sys.executable, "-m", "pip"]
    assert cmd[-1] == "yt-dlp"
    assert "--target" not in cmd


def test_packaged_app_updates_into_user_overlay_only():
    target = "/Users/me/Library/Application Support/Setlist/packages"

    cmd = yt_dlp_update_command(target)

    assert cmd[-2:] == ["--target", target]
    assert "--no-deps" in cmd, "the overlay must hold yt-dlp alone"
    assert "-U" in cmd
