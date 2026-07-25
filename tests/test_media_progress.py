from io import StringIO

import pytest

from app.core import downloader
from app.core.downloader import DownloadProgress, download_audio, encode, parse_ffmpeg_progress
from app.core.job_state import CancellationToken, JobCancelled


def test_download_progress_from_yt_dlp_payload():
    progress = DownloadProgress.from_yt_dlp({
        "downloaded_bytes": 25,
        "total_bytes": 100,
        "speed": 12.5,
        "eta": 6,
    })
    assert progress.pct == 25.0
    assert progress.downloaded_bytes == 25
    assert progress.speed_bytes_per_second == 12.5
    assert progress.eta_seconds == 6


def test_parse_ffmpeg_progress_uses_output_time():
    assert parse_ffmpeg_progress("out_time_us=5000000", duration_seconds=10) == 50.0


def test_cancelled_token_raises_from_progress_hook():
    token = CancellationToken()
    token.cancel()
    with pytest.raises(JobCancelled):
        token.raise_if_cancelled()


def test_download_audio_publishes_structured_progress(monkeypatch, tmp_path):
    destination = tmp_path / "source.webm"

    class FakeYoutubeDL:
        def __init__(self, options):
            self.options = options

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def extract_info(self, url, download):
            hook = self.options["progress_hooks"][0]
            hook({
                "status": "downloading",
                "downloaded_bytes": 25,
                "total_bytes": 100,
                "speed": 12.5,
                "eta": 6,
            })
            destination.write_bytes(b"audio")
            hook({"status": "finished", "filename": str(destination)})
            return {}

    monkeypatch.setattr(downloader, "YoutubeDL", FakeYoutubeDL)
    events = []

    result = download_audio("https://example.test/video", tmp_path, events.append)

    assert result == destination
    assert events == [
        DownloadProgress(25.0, 25, 100, 12.5, 6),
        DownloadProgress(100.0),
    ]


def test_download_audio_checks_cancellation_before_publishing(monkeypatch, tmp_path):
    class FakeYoutubeDL:
        def __init__(self, options):
            self.options = options

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def extract_info(self, url, download):
            self.options["progress_hooks"][0]({
                "status": "downloading",
                "downloaded_bytes": 1,
                "total_bytes": 2,
            })

    monkeypatch.setattr(downloader, "YoutubeDL", FakeYoutubeDL)
    token = CancellationToken()
    token.cancel()
    events = []

    with pytest.raises(JobCancelled):
        download_audio(
            "https://example.test/video",
            tmp_path,
            events.append,
            cancellation=token,
        )

    assert events == []


def test_encode_terminates_ffmpeg_when_cancelled(monkeypatch, tmp_path):
    class FakeProcess:
        def __init__(self):
            self.stdout = StringIO("out_time_us=1000000\nout_time_us=2000000\n")
            self.stderr = StringIO()
            self.returncode = None
            self.terminated = False

        def terminate(self):
            self.terminated = True

        def wait(self):
            self.returncode = -15
            return self.returncode

    process = FakeProcess()
    command = []
    monkeypatch.setattr(downloader, "probe_duration", lambda path: 10.0)

    def fake_popen(cmd, **kwargs):
        command.extend(cmd)
        return process

    monkeypatch.setattr(downloader.subprocess, "Popen", fake_popen)
    token = CancellationToken()
    events = []

    def on_progress(pct):
        events.append(pct)
        token.cancel()

    with pytest.raises(JobCancelled):
        encode(
            tmp_path / "source.m4a",
            tmp_path / "dest.m4a",
            "alac",
            on_progress=on_progress,
            cancellation=token,
        )

    assert events == [10.0]
    assert process.terminated is True
    assert command[command.index("-loglevel") + 1] == "error"
    assert command[command.index("-progress") + 1] == "pipe:1"
    assert "-nostats" in command
