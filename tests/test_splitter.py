import shutil
import subprocess
from pathlib import Path

import pytest
from mutagen.mp4 import MP4

from app.core import splitter
from app.core.job_state import CancellationToken, JobCancelled
from app.core.splitter import compute_end_times, split_file
from app.models import Track


def _has_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


@pytest.fixture
def long_m4a(tmp_path) -> Path:
    """A 6-second AAC .m4a built with ffmpeg; skips if ffmpeg is unavailable."""
    if not _has_ffmpeg():
        pytest.skip("ffmpeg not installed")
    out = tmp_path / "full.m4a"
    subprocess.run(
        [
            "ffmpeg", "-y", "-f", "lavfi",
            "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
            "-t", "6", "-c:a", "aac", "-b:a", "96k", str(out),
        ],
        check=True, capture_output=True,
    )
    return out


def test_compute_end_times_fills_gaps():
    tracks = [Track(start=0, title="A"), Track(start=2, title="B"), Track(start=4, title="C")]
    out = compute_end_times(tracks, 6.0)
    assert [t.end for t in out] == [2.0, 4.0, 6.0]


def test_compute_end_times_sorts_first():
    tracks = [Track(start=4, title="C"), Track(start=0, title="A"), Track(start=2, title="B")]
    out = compute_end_times(tracks, 6.0)
    assert [t.start for t in out] == [0, 2, 4]
    assert [t.end for t in out] == [2.0, 4.0, 6.0]


def test_split_file_creates_ordered_segments(long_m4a, tmp_path):
    tracks = [Track(start=0, title="A"), Track(start=2, title="B"), Track(start=4, title="C")]
    out_dir = tmp_path / "cuts"
    files = split_file(long_m4a, tracks, out_dir, total_duration=6.0)
    assert [f.name for f in files] == ["01 - A.m4a", "02 - B.m4a", "03 - C.m4a"]
    for f in files:
        assert f.exists()
        dur = MP4(str(f)).info.length
        assert 1.5 < dur < 2.6  # ~2s each (stream-copy boundaries snap to packets)


def test_split_file_probes_duration_when_missing(long_m4a, tmp_path):
    tracks = [Track(start=0, title="A"), Track(start=3, title="B")]
    files = split_file(long_m4a, tracks, tmp_path / "cuts")
    assert len(files) == 2
    assert 2.6 < MP4(str(files[1])).info.length < 3.4  # last = file end (~6s) - 3s ≈ 3s


def test_split_file_rejects_missing_start(long_m4a, tmp_path):
    tracks = [Track(start=0, title="A"), Track(start=None, title="B")]
    with pytest.raises(ValueError):
        split_file(long_m4a, tracks, tmp_path / "cuts", total_duration=6.0)


def test_split_file_checks_cancellation_before_each_cut(monkeypatch, tmp_path):
    tracks = [Track(start=0, title="A"), Track(start=2, title="B")]
    cuts = []
    events = []
    token = CancellationToken()

    def fake_cut(full, start, end, dest):
        cuts.append(dest.name)

    def on_track(index, total, title):
        events.append((index, total, title))
        token.cancel()

    monkeypatch.setattr(splitter, "_cut", fake_cut)

    with pytest.raises(JobCancelled):
        split_file(
            tmp_path / "full.m4a",
            tracks,
            tmp_path / "cuts",
            total_duration=4.0,
            on_track=on_track,
            cancellation=token,
        )

    assert cuts == ["01 - A.m4a"]
    assert events == [(1, 2, "A")]
