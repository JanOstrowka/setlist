import os
import time
from pathlib import Path

from app.core.master_cache import MasterCache


def _write(path: Path, size: int) -> Path:
    path.write_bytes(b"x" * size)
    return path


def _age(path: Path, seconds: float) -> None:
    stamp = time.time() - seconds
    os.utime(path, (stamp, stamp))


def test_store_then_lookup_round_trips_per_format(tmp_path):
    cache = MasterCache(tmp_path / "masters", max_bytes=1024)
    source = _write(tmp_path / "full.m4a", 100)

    stored = cache.store(source, "abcDEF12345", "alac")

    assert stored is not None
    assert stored.read_bytes() == source.read_bytes()
    assert cache.lookup("abcDEF12345", "alac") == stored
    assert cache.lookup("abcDEF12345", "aac256") is None
    assert cache.lookup("otherVideo0", "alac") is None
    # The source is left alone; the cache keeps its own copy.
    assert source.exists()


def test_video_id_is_sanitised_into_the_file_name(tmp_path):
    cache = MasterCache(tmp_path / "masters", max_bytes=1024)

    path = cache.path_for("../evil/../id", "alac")

    assert path.parent == tmp_path / "masters"
    assert ".." not in path.name and "/" not in path.name


def test_prune_drops_the_least_recently_used_masters_first(tmp_path):
    cache = MasterCache(tmp_path / "masters", max_bytes=250)
    a = cache.store(_write(tmp_path / "a", 100), "aaaaaaaaaaa", "alac")
    _age(a, 300)
    b = cache.store(_write(tmp_path / "b", 100), "bbbbbbbbbbb", "alac")
    _age(b, 200)
    # Using A makes it recent again, so B is now the oldest.
    assert cache.lookup("aaaaaaaaaaa", "alac") == a

    cache.store(_write(tmp_path / "c", 100), "ccccccccccc", "alac")

    assert cache.lookup("aaaaaaaaaaa", "alac") is not None
    assert cache.lookup("bbbbbbbbbbb", "alac") is None
    assert cache.lookup("ccccccccccc", "alac") is not None


def test_a_master_larger_than_the_budget_is_not_kept(tmp_path):
    cache = MasterCache(tmp_path / "masters", max_bytes=50)

    stored = cache.store(_write(tmp_path / "big", 100), "aaaaaaaaaaa", "alac")

    assert stored is None
    assert cache.lookup("aaaaaaaaaaa", "alac") is None


def test_zero_budget_disables_the_cache(tmp_path):
    cache = MasterCache(tmp_path / "masters", max_bytes=0)

    assert cache.store(_write(tmp_path / "full", 10), "aaaaaaaaaaa", "alac") is None
    assert cache.lookup("aaaaaaaaaaa", "alac") is None
    assert not (tmp_path / "masters").exists()


def test_empty_or_partial_files_do_not_count_as_hits(tmp_path):
    cache = MasterCache(tmp_path / "masters", max_bytes=1024)
    cache.root.mkdir(parents=True)
    cache.path_for("aaaaaaaaaaa", "alac").write_bytes(b"")

    assert cache.lookup("aaaaaaaaaaa", "alac") is None


def test_store_failure_is_swallowed(tmp_path):
    # The cache lives under a regular file, so nothing can be created there.
    blocker = tmp_path / "blocker"
    blocker.write_text("not a directory")
    cache = MasterCache(blocker / "masters", max_bytes=1024)

    assert cache.store(_write(tmp_path / "full", 10), "aaaaaaaaaaa", "alac") is None
