from pathlib import Path


def test_run_script_can_suppress_browser_launch():
    script = (Path(__file__).parent.parent / "run.sh").read_text()

    assert 'if [ "${OPEN_BROWSER:-1}" = "1" ]; then' in script
