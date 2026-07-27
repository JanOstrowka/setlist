from io import StringIO
import subprocess
import threading

import pytest

from app.core import downloader
from app.core.downloader import DownloadProgress, download_audio, encode, parse_ffmpeg_progress
from app.core.job_state import CancellationToken, JobCancelled


class FakeProcess:
    def __init__(self, stdout="", wait_results=None):
        self.stdout = StringIO(stdout)
        self.stderr = StringIO()
        self.returncode = None
        self.terminated = False
        self.killed = False
        self.wait_results = list(wait_results or [0])
        self.wait_timeouts = []

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True

    def wait(self, timeout=None):
        self.wait_timeouts.append(timeout)
        result = self.wait_results.pop(0)
        if isinstance(result, BaseException):
            raise result
        self.returncode = result
        return result


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


def test_download_audio_retries_transient_broken_pipe(monkeypatch, tmp_path):
    destination = tmp_path / "source.webm"
    attempts = []

    class FlakyYoutubeDL:
        def __init__(self, options):
            self.options = options

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def extract_info(self, url, download):
            attempts.append(url)
            if len(attempts) == 1:
                raise RuntimeError(
                    "Unable to download video: [Errno 32] Broken pipe"
                )
            destination.write_bytes(b"audio")
            hook = self.options["progress_hooks"][0]
            hook({"status": "finished", "filename": str(destination)})
            return {}

    monkeypatch.setattr(downloader, "YoutubeDL", FlakyYoutubeDL)
    monkeypatch.setattr(downloader.time, "sleep", lambda _: None)

    result = download_audio("https://example.test/video", tmp_path, lambda _: None)

    assert result == destination
    assert len(attempts) == 2


def test_download_audio_does_not_retry_nontransient_errors(monkeypatch, tmp_path):
    attempts = []

    class FailingYoutubeDL:
        def __init__(self, options):
            self.options = options

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def extract_info(self, url, download):
            attempts.append(url)
            raise RuntimeError("Video unavailable")

    monkeypatch.setattr(downloader, "YoutubeDL", FailingYoutubeDL)
    monkeypatch.setattr(downloader.time, "sleep", lambda _: None)

    with pytest.raises(RuntimeError, match="Video unavailable"):
        download_audio("https://example.test/video", tmp_path, lambda _: None)

    assert len(attempts) == 1


def test_download_audio_gives_up_after_bounded_transient_retries(monkeypatch, tmp_path):
    attempts = []

    class AlwaysBrokenYoutubeDL:
        def __init__(self, options):
            self.options = options

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def extract_info(self, url, download):
            attempts.append(url)
            raise RuntimeError("[Errno 32] Broken pipe")

    monkeypatch.setattr(downloader, "YoutubeDL", AlwaysBrokenYoutubeDL)
    monkeypatch.setattr(downloader.time, "sleep", lambda _: None)

    with pytest.raises(RuntimeError, match="Broken pipe"):
        download_audio("https://example.test/video", tmp_path, lambda _: None)

    assert len(attempts) == downloader._DOWNLOAD_ATTEMPTS


def test_download_audio_does_not_retry_cancellation(monkeypatch, tmp_path):
    attempts = []
    token = CancellationToken()

    class CancellingYoutubeDL:
        def __init__(self, options):
            self.options = options

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def extract_info(self, url, download):
            attempts.append(url)
            token.cancel()
            token.raise_if_cancelled()

    monkeypatch.setattr(downloader, "YoutubeDL", CancellingYoutubeDL)
    monkeypatch.setattr(downloader.time, "sleep", lambda _: None)

    with pytest.raises(JobCancelled):
        download_audio(
            "https://example.test/video",
            tmp_path,
            lambda _: None,
            cancellation=token,
        )

    assert len(attempts) == 1


def test_download_audio_uses_resilient_transport_options(monkeypatch, tmp_path):
    captured = {}
    destination = tmp_path / "source.webm"

    class RecordingYoutubeDL:
        def __init__(self, options):
            captured.update(options)
            self.options = options

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def extract_info(self, url, download):
            destination.write_bytes(b"audio")
            hook = self.options["progress_hooks"][0]
            hook({"status": "finished", "filename": str(destination)})
            return {}

    monkeypatch.setattr(downloader, "YoutubeDL", RecordingYoutubeDL)

    download_audio("https://example.test/video", tmp_path, lambda _: None)

    assert captured["retries"] == 10
    assert captured["fragment_retries"] == 10
    assert captured["socket_timeout"] == 20
    assert captured["http_chunk_size"] == 10 * 1024 * 1024
    # The console progress bar must stay off: writing it to a dead stdout
    # (orphaned backend) raises EPIPE and kills otherwise healthy downloads.
    assert captured["noprogress"] is True


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
    process = FakeProcess(
        "out_time_us=1000000\nout_time_us=2000000\n",
        wait_results=[-15],
    )
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


def test_encode_kills_ffmpeg_when_terminate_times_out(monkeypatch, tmp_path):
    process = FakeProcess(
        "out_time_us=1000000\nout_time_us=2000000\n",
        wait_results=[
            subprocess.TimeoutExpired("ffmpeg", 1),
            -9,
        ],
    )
    joins = []
    real_thread = threading.Thread

    class TrackingThread(real_thread):
        def join(self, timeout=None):
            joins.append(timeout)
            return super().join(timeout)

    monkeypatch.setattr(downloader, "probe_duration", lambda path: 10.0)
    monkeypatch.setattr(downloader.subprocess, "Popen", lambda *args, **kwargs: process)
    monkeypatch.setattr(downloader.threading, "Thread", TrackingThread)
    token = CancellationToken()

    def cancel_after_progress(pct):
        token.cancel()

    with pytest.raises(JobCancelled):
        encode(
            tmp_path / "source.m4a",
            tmp_path / "dest.m4a",
            "alac",
            on_progress=cancel_after_progress,
            cancellation=token,
        )

    assert process.terminated is True
    assert process.killed is True
    assert len(process.wait_timeouts) == 2
    assert all(timeout is not None and timeout > 0 for timeout in process.wait_timeouts)
    assert joins and all(timeout is not None and timeout > 0 for timeout in joins)


def test_encode_cleans_up_when_progress_callback_raises(monkeypatch, tmp_path):
    process = FakeProcess("out_time_us=1000000\n", wait_results=[-15])
    joins = []
    real_thread = threading.Thread

    class TrackingThread(real_thread):
        def join(self, timeout=None):
            joins.append(timeout)
            return super().join(timeout)

    monkeypatch.setattr(downloader, "probe_duration", lambda path: 10.0)
    monkeypatch.setattr(downloader.subprocess, "Popen", lambda *args, **kwargs: process)
    monkeypatch.setattr(downloader.threading, "Thread", TrackingThread)

    def fail_on_progress(pct):
        raise LookupError("progress callback failed")

    with pytest.raises(LookupError, match="progress callback failed"):
        encode(
            tmp_path / "source.m4a",
            tmp_path / "dest.m4a",
            "alac",
            on_progress=fail_on_progress,
        )

    assert process.terminated is True
    assert process.killed is False
    assert process.wait_timeouts and process.wait_timeouts[0] is not None
    assert joins and joins[0] is not None


def test_encode_cleans_up_when_progress_line_is_malformed(monkeypatch, tmp_path):
    process = FakeProcess("out_time_us=not-a-number\n", wait_results=[-15])
    monkeypatch.setattr(downloader, "probe_duration", lambda path: 10.0)
    monkeypatch.setattr(downloader.subprocess, "Popen", lambda *args, **kwargs: process)

    with pytest.raises(ValueError):
        encode(
            tmp_path / "source.m4a",
            tmp_path / "dest.m4a",
            "alac",
        )

    assert process.terminated is True
    assert process.wait_timeouts and process.wait_timeouts[0] is not None


@pytest.mark.parametrize(
    "probe_error",
    [
        subprocess.CalledProcessError(
            1,
            ["ffprobe"],
            stderr="invalid media",
        ),
        ValueError("could not convert string to float: ''"),
    ],
)
def test_encode_maps_probe_failures_to_encode_error(monkeypatch, tmp_path, probe_error):
    monkeypatch.setattr(downloader, "probe_duration", lambda path: (_ for _ in ()).throw(probe_error))
    popen_called = False

    def fake_popen(*args, **kwargs):
        nonlocal popen_called
        popen_called = True

    monkeypatch.setattr(downloader.subprocess, "Popen", fake_popen)

    with pytest.raises(RuntimeError, match=r"^ffmpeg encode failed:"):
        encode(
            tmp_path / "source.m4a",
            tmp_path / "dest.m4a",
            "alac",
        )

    assert popen_called is False


@pytest.mark.parametrize("duration", [0.0, float("nan")])
def test_encode_rejects_invalid_probe_duration(monkeypatch, tmp_path, duration):
    monkeypatch.setattr(downloader, "probe_duration", lambda path: duration)
    monkeypatch.setattr(
        downloader.subprocess,
        "Popen",
        lambda *args, **kwargs: pytest.fail("ffmpeg must not start"),
    )

    with pytest.raises(RuntimeError, match=r"^ffmpeg encode failed:"):
        encode(
            tmp_path / "source.m4a",
            tmp_path / "dest.m4a",
            "alac",
        )


def test_encode_preserves_successful_progress(monkeypatch, tmp_path):
    process = FakeProcess("out_time_us=1000000\nprogress=end\n", wait_results=[0])
    monkeypatch.setattr(downloader, "probe_duration", lambda path: 10.0)
    monkeypatch.setattr(downloader.subprocess, "Popen", lambda *args, **kwargs: process)
    events = []

    encode(
        tmp_path / "source.m4a",
        tmp_path / "dest.m4a",
        "alac",
        on_progress=events.append,
    )

    assert events == [10.0, 100.0]
    assert process.terminated is False
    assert process.killed is False
